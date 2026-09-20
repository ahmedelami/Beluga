// Opt-in diagnostic only. The supervisor owns deadlines; callbacks never inspect PCM.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include "OpensteamerVirtualMicrophoneDriver.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <libproc.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const char *kDriverPath = "/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver/Contents/MacOS/OpensteamerVirtualMicrophone";
static volatile sig_atomic_t gCancelled;
static _Atomic bool gGate;
static _Atomic bool gMonitorDone;
static _Atomic bool gGuardFailed;
static _Atomic uint64_t gCallbacks;
static _Atomic uint64_t gWriterCallbacks;
static _Atomic uint64_t gTapCallbacks;
static _Atomic bool gForeignOutputObserved;
static _Atomic bool gOwnOutputObserved;
static _Atomic bool gPeerOutputObserved;
static _Atomic(const char *) gFailureStage = "preflight";
static _Atomic uint64_t gFrames;
static _Atomic uint64_t gValidTimestamps;
static _Atomic uint64_t gAdvancingTimestamps;
static _Atomic uint64_t gReaderInvocations;
static _Atomic unsigned gReaderInFlight;
static bool gProductionAligned;
static double gLastSampleTime;
static uint64_t gLastHostTime;
static _Atomic int32_t gCallbackError;
static pid_t gOtherPID;
static pid_t gSupervisorPID;
static pid_t gHostPID;
static uint64_t gHostStartSeconds, gHostStartMicroseconds;
static struct stat gHostFile;
static struct stat gDriverFile;
static const char *kHostPath = "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer";
static char gExecutablePath[PROC_PIDPATHINFO_MAXSIZE];
static NSString *gRunID;
static NSString *gClockUID;
static NSString *gDefaultUIDs[3];
static AudioDeviceID gDefaults[3];
static AudioDeviceID gVisible, gHidden, gClock;
static uint64_t gDriverInstance;
static const AudioObjectPropertySelector kDefaults[3] = {
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultSystemOutputDevice,
};
static _Atomic uint64_t gSelectorNotifications;
static unsigned gListeners;

static uint64_t Now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static void Event(const char *event, const char *stage, int64_t value) {
    printf("{\"schema\":1,\"event\":\"%s\",\"stage\":\"%s\",\"value\":%lld,\"monotonicNS\":%llu,\"pid\":%d}\n",
           event, stage, (long long)value, (unsigned long long)Now(), getpid());
    fflush(stdout);
}

_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "The signal handler requires a lock-free admission gate");
static void Cancel(int number) {
    (void)number;
    atomic_store_explicit(&gGate, false, memory_order_relaxed);
    gCancelled = 1;
}
static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static OSStatus Read(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, void *value, UInt32 bytes) {
    AudioObjectPropertyAddress address = Address(selector, scope);
    UInt32 size = bytes;
    OSStatus status = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value);
    return status == noErr && size != bytes ? kAudioHardwareBadPropertySizeError : status;
}
static NSString *StringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    if (Read(object, selector, kAudioObjectPropertyScopeGlobal, &value, sizeof(value)) != noErr || value == NULL) return nil;
    if (CFGetTypeID(value) != CFStringGetTypeID()) { CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}
static AudioDeviceID Resolve(NSString *uid) {
    CFStringRef qualifier = (__bridge CFStringRef)uid;
    AudioDeviceID device = 0;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = Address(kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(qualifier), &qualifier, &size, &device) != noErr || size != sizeof(device)) return 0;
    return [StringProperty(device, kAudioDevicePropertyDeviceUID) isEqualToString:uid] ? device : 0;
}
static NSArray<NSNumber *> *ObjectList(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size > 4096 * sizeof(AudioObjectID) || size % sizeof(AudioObjectID)) return nil;
    if (size == 0) return @[];
    AudioObjectID values[4096];
    UInt32 actual = size;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &actual, values) != noErr || actual != size) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); ++i) [result addObject:@(values[i])];
    return result;
}
static bool Snapshot(OSVADiagnosticSnapshot *snapshot) {
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        CFPropertyListRef value = NULL;
        OSStatus status = Read(gVisible, kOSVADiagnosticSnapshotProperty, kAudioObjectPropertyScopeGlobal, &value, sizeof(value));
        if (status != noErr) continue;
        bool valid = value && CFGetTypeID(value) == CFDataGetTypeID() && CFDataGetLength(value) == sizeof(*snapshot);
        if (valid) CFDataGetBytes(value, CFRangeMake(0, sizeof(*snapshot)), (UInt8 *)snapshot);
        if (value) CFRelease(value);
        if (!valid) return false;
        const uint64_t invariants = ((UINT64_C(1) << 18) - (UINT64_C(1) << 8));
        return snapshot->schema_version == kOSVADiagnosticSnapshotSchemaVersion &&
            snapshot->struct_size == sizeof(*snapshot) && snapshot->client_slot_capacity == kOSVADiagnosticClientSlotCapacity &&
            snapshot->driver_instance_generation == gDriverInstance &&
            (snapshot->invariant_flags & invariants) == invariants;
    }
    return false;
}
static bool ExpectedProcess(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return pid > 1 && proc_pidpath(pid, path, sizeof(path)) > 0 && strcmp(path, gExecutablePath) == 0;
}
static bool Reject(const char *stage) { atomic_store(&gFailureStage, stage); return false; }
// -1 = unknown (fail closed), 0 = a named non-host, 1 = possible host.
// This public typed name is sufficient only for candidate discovery. A host
// candidate must still pass the full pinned PID/path/start/file checks below.
static int PublicProcessClass(pid_t pid, int status, size_t bytes, const struct kinfo_proc *info) {
    if (status != 0 || bytes != sizeof(*info) || info->kp_proc.p_pid != pid || !info->kp_proc.p_comm[0] ||
        !memchr(info->kp_proc.p_comm, '\0', sizeof(info->kp_proc.p_comm))) return -1;
    return strcmp(info->kp_proc.p_comm, "CaptureServer") == 0 ? 1 : 0;
}
static int TestPublicProcessClass(void) {
    struct kinfo_proc info = {0}; info.kp_proc.p_pid = 123;
    strcpy(info.kp_proc.p_comm, "CaptureServer");
    unsigned checks = 0;
#define EXPECT_CLASS(expected, pid, status, bytes) do { \
    if (PublicProcessClass((pid), (status), (bytes), &info) != (expected)) return 1; ++checks; \
} while (0)
    EXPECT_CLASS(1, 123, 0, sizeof(info));
    EXPECT_CLASS(-1, 124, 0, sizeof(info));
    EXPECT_CLASS(-1, 123, -1, sizeof(info));
    EXPECT_CLASS(-1, 123, 0, 0);
    EXPECT_CLASS(-1, 123, 0, sizeof(info) - 1);
    info.kp_proc.p_stat = SZOMB; // A zombie named host is not silently ignored.
    EXPECT_CLASS(1, 123, 0, sizeof(info));
    strcpy(info.kp_proc.p_comm, "launchd");
    EXPECT_CLASS(0, 123, 0, sizeof(info));
    memset(info.kp_proc.p_comm, 0, sizeof(info.kp_proc.p_comm));
    EXPECT_CLASS(-1, 123, 0, sizeof(info));
    memset(info.kp_proc.p_comm, 'x', sizeof(info.kp_proc.p_comm));
    EXPECT_CLASS(-1, 123, 0, sizeof(info));
#undef EXPECT_CLASS
    Event("checked", "offline_public_process_class_contracts", checks);
    return 0;
}
static NSString *OutputClassification(pid_t pid, NSString *bundleID, bool canonicalHost) {
    if (pid == getpid()) return @"inspector";
    if ([bundleID isEqual:@"com.elamin.opensteamer.TapStartupDiagnostic"]) return @"diagnostic_probe";
    if (canonicalHost) return @"canonical_host_path";
    return bundleID.length ? @"other_bundle" : @"bundle_unavailable";
}
static int TestOutputClassification(void) {
    if (![OutputClassification(getpid(), nil, false) isEqual:@"inspector"] ||
        ![OutputClassification(-1, @"com.elamin.opensteamer.TapStartupDiagnostic", false) isEqual:@"diagnostic_probe"] ||
        ![OutputClassification(-1, @"com.example.other", true) isEqual:@"canonical_host_path"] ||
        ![OutputClassification(-1, @"com.example.other", false) isEqual:@"other_bundle"] ||
        ![OutputClassification(-1, nil, false) isEqual:@"bundle_unavailable"]) return 1;
    Event("checked", "offline_output_classification_contracts", 5);
    return 0;
}
static int OutputActivityCheck(void) {
    // A public metadata query only: no tap, aggregate, queue, or IOProc creation.
    NSArray<NSNumber *> *processes = ObjectList(kAudioHardwarePropertyProcessObjectList);
    if (!processes) { Event("guard_failed", "process_output_scan", 1); return 65; }
    unsigned runningCount = 0, unavailableCount = 0;
    for (NSNumber *object in processes) {
        UInt32 running = 0; pid_t pid = 0;
        if (Read(object.unsignedIntValue, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, &running, sizeof(running)) != noErr) {
            ++unavailableCount; continue;
        }
        if (!running) continue;
        ++runningCount;
        if (runningCount > 16) continue;
        OSStatus pidStatus = Read(object.unsignedIntValue, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid, sizeof(pid));
        if (pidStatus != noErr) ++unavailableCount;
        NSString *bundleID = StringProperty(object.unsignedIntValue, kAudioProcessPropertyBundleID);
        if (bundleID.length > 256) bundleID = nil;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        bool canonicalHost = pidStatus == noErr && proc_pidpath(pid, path, sizeof(path)) > 0 && strcmp(path, kHostPath) == 0;
        NSDictionary *record = @{@"schema": @1, @"event": @"output_activity", @"inspectorPID": @(getpid()),
            @"processObjectID": object, @"processPID": @(pid), @"pidReadStatus": @(pidStatus),
            @"runningOutput": @(running), @"bundleID": bundleID ?: (id)[NSNull null],
            @"classification": OutputClassification(pid, bundleID, canonicalHost), @"monotonicNS": @(Now())};
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
        if (!encoded) return 65;
        fwrite(encoded.bytes, 1, encoded.length, stdout); fputc('\n', stdout); fflush(stdout);
    }
    Event("checked", "running_output_process_count", runningCount);
    Event("checked", "output_metadata_unavailable_count", unavailableCount);
    Event("checked", "output_inspection_complete", runningCount <= 16 && unavailableCount == 0);
    return runningCount <= 16 && unavailableCount == 0 ? 0 : 65;
}
static int HostScanDiagnostic(void) {
    pid_t pids[8192];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    if (bytes <= 0 || bytes >= (int)sizeof(pids)) { Event("guard_failed", "host_process_list", bytes); return 65; }
    unsigned unresolved = 0, hosts = 0, publicResolved = 0, publicHosts = 0;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); ++i) {
        if (pids[i] <= 0) continue;
        char name[256] = {0};
        errno = 0;
        int named = proc_name(pids[i], name, sizeof(name));
        int nameError = errno;
        if (named > 0 && strcmp(name, "CaptureServer") == 0) {
            ++hosts; Event("checked", "named_host_pid", pids[i]);
        }
        if (named > 0) continue;
        ++unresolved;
        struct proc_bsdinfo info = {0};
        errno = 0;
        int read = proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info));
        int metadataError = errno;
        struct kinfo_proc publicInfo = {0};
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pids[i]};
        size_t publicBytes = sizeof(publicInfo);
        errno = 0;
        int publicStatus = sysctl(mib, 4, &publicInfo, &publicBytes, NULL, 0);
        int publicError = errno;
        int classification = PublicProcessClass(pids[i], publicStatus, publicBytes, &publicInfo);
        bool publicValid = classification >= 0;
        bool publicHost = classification == 1;
        publicResolved += publicValid; publicHosts += publicHost;
        if (unresolved > 8) continue;
        Event("checked", "unresolved_process_pid", pids[i]);
        Event("checked", "process_name_errno", nameError);
        Event("checked", "process_bsd_bytes", read);
        Event("checked", "process_bsd_errno", metadataError);
        Event("checked", "process_public_status", publicStatus);
        Event("checked", "process_public_errno", publicError);
        Event("checked", "process_public_bytes", (int64_t)publicBytes);
        Event("checked", "process_public_valid", publicValid);
        Event("checked", "process_public_is_host", publicHost);
        if (read == sizeof(info)) {
            Event("checked", "process_bsd_pid_matches", info.pbi_pid == (uint32_t)pids[i]);
            Event("checked", "process_bsd_status", info.pbi_status);
            Event("checked", "process_bsd_name_nonempty", info.pbi_name[0] != 0);
            Event("checked", "process_bsd_comm_nonempty", info.pbi_comm[0] != 0);
            Event("checked", "process_bsd_name_is_host", strncmp(info.pbi_name, "CaptureServer", sizeof(info.pbi_name)) == 0);
            Event("checked", "process_bsd_comm_is_host", strncmp(info.pbi_comm, "CaptureServer", sizeof(info.pbi_comm)) == 0);
        }
    }
    Event("checked", "unresolved_process_count", unresolved);
    Event("checked", "named_host_count", hosts);
    Event("checked", "public_resolved_count", publicResolved);
    Event("checked", "public_host_count", publicHosts);
    return 0;
}
static bool HostMatches(void) {
    pid_t pids[8192];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    if (bytes <= 0 || bytes >= (int)sizeof(pids)) return Reject("host_process_list");
    bool found = false;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); ++i) {
        if (pids[i] <= 0) continue;
        char name[256] = {0};
        bool candidate = false;
        if (proc_name(pids[i], name, sizeof(name)) > 0) {
            candidate = strcmp(name, "CaptureServer") == 0;
        } else {
            // proc_name/PROC_PIDTBSDINFO may deny unrelated system processes.
            // KERN_PROC_PID exposes a public typed command name without privilege.
            struct kinfo_proc info = {0};
            int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pids[i]};
            size_t size = sizeof(info);
            int status = sysctl(mib, 4, &info, &size, NULL, 0);
            int classification = PublicProcessClass(pids[i], status, size, &info);
            if (classification < 0) {
                if (status == 0 && size == 0 && kill(pids[i], 0) != 0 && errno == ESRCH) continue;
                return Reject("host_public_process_metadata_unknown");
            }
            candidate = classification == 1;
        }
        if (candidate) {
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            struct proc_bsdinfo info = {0};
            struct stat current;
            if (found || pids[i] != gHostPID) return Reject("host_pid_or_ambiguity");
            if (proc_pidpath(pids[i], path, sizeof(path)) <= 0 || strcmp(path, kHostPath)) return Reject("host_path");
            if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return Reject("host_bsd_metadata");
            if (info.pbi_start_tvsec != gHostStartSeconds || info.pbi_start_tvusec != gHostStartMicroseconds) return Reject("host_start_tuple");
            if (lstat(kHostPath, &current) != 0 || current.st_dev != gHostFile.st_dev || current.st_ino != gHostFile.st_ino ||
                current.st_mtimespec.tv_sec != gHostFile.st_mtimespec.tv_sec || current.st_mtimespec.tv_nsec != gHostFile.st_mtimespec.tv_nsec ||
                current.st_ctimespec.tv_sec != gHostFile.st_ctimespec.tv_sec || current.st_ctimespec.tv_nsec != gHostFile.st_ctimespec.tv_nsec ||
                current.st_size != gHostFile.st_size) return Reject("host_file_identity");
            found = true;
        }
    }
    return found == (gHostPID != 0) || Reject("host_presence");
}
static bool SelectorsMatch(bool initialize) {
    if (atomic_load(&gSelectorNotifications) != 0) return false;
    for (unsigned i = 0; i < 3; ++i) {
        AudioDeviceID current = 0;
        if (Read(kAudioObjectSystemObject, kDefaults[i], kAudioObjectPropertyScopeGlobal, &current, sizeof(current)) != noErr ||
            ![StringProperty(current, kAudioDevicePropertyDeviceUID) isEqualToString:gDefaultUIDs[i]]) return false;
        if (initialize) gDefaults[i] = current;
        else if (current != gDefaults[i]) return false;
    }
    return atomic_load(&gSelectorNotifications) == 0;
}
static OSStatus SelectorChanged(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses, void *context) {
    (void)object; (void)count; (void)addresses; (void)context;
    atomic_fetch_add(&gSelectorNotifications, 1);
    atomic_store(&gGate, false);
    return noErr;
}
static bool TapSetIsOwned(bool requireEmpty) {
    NSArray<NSNumber *> *taps = ObjectList(kAudioHardwarePropertyTapList);
    if (!taps || taps.count > (requireEmpty ? 0U : 1U)) return false;
    for (NSNumber *tap in taps) {
        if (![StringProperty(tap.unsignedIntValue, kAudioTapPropertyUID) isEqualToString:gRunID]) return false;
    }
    return true;
}
static bool ObserveForeignOutput(void) {
    NSArray<NSNumber *> *processes = ObjectList(kAudioHardwarePropertyProcessObjectList);
    if (!processes) return false;
    for (NSNumber *object in processes) {
        pid_t pid = 0; UInt32 running = 0;
        if (Read(object.unsignedIntValue, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid, sizeof(pid)) != noErr ||
            Read(object.unsignedIntValue, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, &running, sizeof(running)) != noErr) return false;
        if (pid == getpid() && running) atomic_store(&gOwnOutputObserved, true);
        if (pid == gOtherPID && running) atomic_store(&gPeerOutputObserved, true);
        if (pid != getpid() && pid != gOtherPID && running) atomic_store(&gForeignOutputObserved, true);
    }
    return true;
}
static bool RuntimeMatches(bool requireIdle) {
    struct stat driverFile;
    if (getppid() != gSupervisorPID || gCancelled) return Reject("supervisor_identity");
    if (!SelectorsMatch(false)) return Reject("default_selectors");
    if (!HostMatches()) return false;
    if (lstat(kDriverPath, &driverFile) != 0 || driverFile.st_dev != gDriverFile.st_dev || driverFile.st_ino != gDriverFile.st_ino ||
        driverFile.st_mtimespec.tv_sec != gDriverFile.st_mtimespec.tv_sec || driverFile.st_mtimespec.tv_nsec != gDriverFile.st_mtimespec.tv_nsec ||
        driverFile.st_ctimespec.tv_sec != gDriverFile.st_ctimespec.tv_sec || driverFile.st_ctimespec.tv_nsec != gDriverFile.st_ctimespec.tv_nsec ||
        driverFile.st_size != gDriverFile.st_size) return Reject("driver_identity");
    if (Resolve(@OSVA_VISIBLE_INPUT_DEVICE_UID) != gVisible || Resolve(@OSVA_HIDDEN_WRITER_DEVICE_UID) != gHidden) return Reject("endpoint_identity");
    if (Resolve(gClockUID) != gClock) return Reject("clock_identity");
    if (!TapSetIsOwned(requireIdle)) return Reject("public_tap_set");
    if (!ObserveForeignOutput()) return Reject("process_output_scan");
    OSVADiagnosticSnapshot snapshot;
    if (!Snapshot(&snapshot)) return Reject("driver_snapshot");
    if (requireIdle && snapshot.active_client_count != 0) return Reject("preexisting_active_client");
    for (unsigned i = 0; i < kOSVADiagnosticClientSlotCapacity; ++i) {
        OSVADiagnosticDriverClientSlotSnapshot slot = snapshot.driver_client_slots[i];
        if ((slot.flags & kOSVADiagnosticDriverSlotStarted) &&
            slot.process_id != getpid() && slot.process_id != gOtherPID) return Reject("foreign_active_client");
    }
    return gOtherPID == 0 || ExpectedProcess(gOtherPID) || Reject("peer_identity");
}
static void *Monitor(void *context) {
    (void)context;
    while (!atomic_load(&gMonitorDone) && !gCancelled) {
        @autoreleasepool {
            if (!RuntimeMatches(false) && !gCancelled) {
                atomic_store(&gGate, false);
                atomic_store(&gGuardFailed, true);
                Event("guard_failed", atomic_load(&gFailureStage), 1);
                break;
            }
        }
        usleep(100000);
    }
    return NULL;
}
static bool Endpoint(AudioDeviceID device, bool visible) {
    UInt32 hidden = 0, alive = 0, clock = 0;
    if (Read(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden, sizeof(hidden)) ||
        Read(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, &alive, sizeof(alive)) ||
        Read(device, kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal, &clock, sizeof(clock)) ||
        hidden != (visible ? 0U : 1U) || alive != 1 || clock != kOSVAClockDomain ||
        ![StringProperty(device, kAudioDevicePropertyModelUID) isEqualToString:@OSVA_DEVICE_MODEL_UID]) return false;
    for (unsigned input = 0; input < 2; ++input) {
        AudioObjectPropertyScope scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
        AudioObjectPropertyAddress address = Address(kAudioDevicePropertyStreams, scope);
        UInt32 bytes = 0;
        bool populated = input == (unsigned)visible;
        if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &bytes) != noErr || bytes != (populated ? sizeof(AudioStreamID) : 0)) return false;
        if (populated) {
            AudioStreamBasicDescription format = {0};
            if (Read(device, kAudioDevicePropertyStreamFormat, scope, &format, sizeof(format)) != noErr ||
                format.mSampleRate != 48000 || format.mChannelsPerFrame != 1 || format.mFormatID != kAudioFormatLinearPCM ||
                format.mFormatFlags != (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) ||
                format.mBitsPerChannel != 32 || format.mBytesPerFrame != 4 || format.mBytesPerPacket != 4 || format.mFramesPerPacket != 1) return false;
        }
    }
    return true;
}
static bool FileHashMatches(const char *path, NSString *expected) {
    struct stat before, after;
    if (lstat(path, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size <= 0 || before.st_size > 128 * 1024 * 1024) return false;
    NSData *data = [NSData dataWithContentsOfFile:@(path) options:NSDataReadingUncached error:nil];
    if (!data || lstat(path, &after) != 0 || before.st_dev != after.st_dev || before.st_ino != after.st_ino || before.st_mtime != after.st_mtime || before.st_size != after.st_size) return false;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (unsigned i = 0; i < sizeof(digest); ++i) [hex appendFormat:@"%02x", digest[i]];
    return [hex isEqualToString:expected];
}
static bool SetupGuards(NSDictionary<NSString *, NSString *> *args) {
    if (!FileHashMatches(kDriverPath, args[@"--driver-sha256"]) || lstat(kDriverPath, &gDriverFile) != 0) return Reject("driver_hash");
    if (gHostPID != 0 && (!FileHashMatches(kHostPath, args[@"--host-sha256"]) || lstat(kHostPath, &gHostFile) != 0)) return Reject("host_hash");
    gVisible = Resolve(@OSVA_VISIBLE_INPUT_DEVICE_UID);
    gHidden = Resolve(@OSVA_HIDDEN_WRITER_DEVICE_UID);
    gClock = Resolve(gClockUID);
    UInt32 transport = 0;
    if (!gVisible || !gHidden || gVisible == gHidden) return Reject("endpoint_identity");
    if (!Endpoint(gVisible, true) || !Endpoint(gHidden, false)) return Reject("endpoint_format");
    if (!gClock || Read(gClock, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport, sizeof(transport)) != noErr ||
        transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate ||
        ![gClockUID isEqualToString:gDefaultUIDs[1]]) return Reject("clock_identity");
    for (unsigned i = 0; i < 3; ++i) {
        AudioObjectPropertyAddress address = Address(kDefaults[i], kAudioObjectPropertyScopeGlobal);
        if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &address, SelectorChanged, NULL) != noErr) return Reject("selector_listener");
        gListeners += 1;
    }
    if (!SelectorsMatch(true)) return Reject("default_selectors");
    return RuntimeMatches(true);
}
static bool RemoveGuards(void) {
    bool success = true;
    for (unsigned i = 0; i < gListeners; ++i) {
        AudioObjectPropertyAddress address = Address(kDefaults[i], kAudioObjectPropertyScopeGlobal);
        if (AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &address, SelectorChanged, NULL) != noErr) success = false;
    }
    gListeners = 0;
    return success;
}
static OSStatus SilentIO(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                         const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime;
    if (output) for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
    if ((uintptr_t)context == 1) atomic_fetch_add(&gWriterCallbacks, 1);
    else if (atomic_load(&gGate)) atomic_fetch_add(&gTapCallbacks, 1);
    return noErr;
}
static void ReaderIO(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer, const AudioTimeStamp *time, UInt32 packets, const AudioStreamPacketDescription *descriptions) {
    (void)context; (void)packets; (void)descriptions;
    if (!atomic_load(&gGate)) return;
    atomic_fetch_add(&gCallbacks, 1);
    atomic_fetch_add(&gFrames, buffer->mAudioDataByteSize / sizeof(Float32));
    // Audio Queue serializes callbacks for this queue; no PCM bytes are read.
    if (time && (time->mFlags & kAudioTimeStampSampleTimeValid) && (time->mFlags & kAudioTimeStampHostTimeValid)) {
        if (atomic_load(&gValidTimestamps) && time->mSampleTime > gLastSampleTime && time->mHostTime > gLastHostTime)
            atomic_fetch_add(&gAdvancingTimestamps, 1);
        gLastSampleTime = time->mSampleTime;
        gLastHostTime = time->mHostTime;
        atomic_fetch_add(&gValidTimestamps, 1);
    }
    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    if (status != noErr) atomic_store(&gCallbackError, status);
}
static bool QueueIsPinned(AudioQueueRef queue, NSString *uid, AudioDeviceID device) {
    CFStringRef current = NULL; UInt32 size = sizeof(current);
    OSStatus status = AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &current, &size);
    bool valid = status == noErr && size == sizeof(current) && current &&
        CFGetTypeID(current) == CFStringGetTypeID() && CFEqual(current, (__bridge CFStringRef)uid) &&
        Resolve(uid) == device;
    if (current) CFRelease(current);
    return valid;
}
static bool WriterFormatMatches(AudioQueueRef queue) {
    AudioStreamBasicDescription format = {0}; UInt32 size = sizeof(format);
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_StreamDescription, &format, &size) != noErr || size != sizeof(format) ||
        format.mSampleRate != 48000 || format.mFormatID != kAudioFormatLinearPCM ||
        format.mFormatFlags != (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked) ||
        format.mChannelsPerFrame != 1 || format.mBitsPerChannel != 16 || format.mBytesPerFrame != 2 ||
        format.mBytesPerPacket != 2 || format.mFramesPerPacket != 1) return false;
    Float64 rate = 0; UInt32 channels = 0;
    size = sizeof(rate);
    if (AudioQueueGetProperty(queue, kAudioQueueDeviceProperty_SampleRate, &rate, &size) != noErr || size != sizeof(rate) || rate != 48000) return false;
    size = sizeof(channels);
    return AudioQueueGetProperty(queue, kAudioQueueDeviceProperty_NumberChannels, &channels, &size) == noErr &&
        size == sizeof(channels) && channels == 1;
}
static void SilentWriterQueueIO(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void)context;
    if (!atomic_load(&gGate)) return;
    // Only owned hidden-endpoint buffers are zeroed; no real-output playback.
    memset(buffer->mAudioData, 0, buffer->mAudioDataBytesCapacity);
    buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
    if (!atomic_load(&gGate)) return;
    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    if (status != noErr) atomic_store(&gCallbackError, status);
    else atomic_fetch_add(&gWriterCallbacks, 1);
}
static void EngineReaderIO(AVAudioPCMBuffer *buffer, AVAudioTime *time) {
    unsigned otherCallbacks = atomic_fetch_add(&gReaderInFlight, 1);
    atomic_fetch_add(&gReaderInvocations, 1);
    // Do not assume AVAudioEngine serializes taps: overlap rejects the arm.
    if (otherCallbacks != 0) {
        atomic_store(&gCallbackError, kAudioHardwareIllegalOperationError);
        atomic_store(&gGate, false);
        atomic_fetch_sub(&gReaderInFlight, 1);
        return;
    }
    if (atomic_load(&gGate)) {
        // Inspect metadata only. Do not access the PCM channel pointers.
        atomic_fetch_add(&gCallbacks, 1);
        atomic_fetch_add(&gFrames, buffer.frameLength);
        if (time.isSampleTimeValid && time.isHostTimeValid) {
            if (atomic_load(&gValidTimestamps) && time.sampleTime > gLastSampleTime && time.hostTime > gLastHostTime)
                atomic_fetch_add(&gAdvancingTimestamps, 1);
            gLastSampleTime = time.sampleTime;
            gLastHostTime = time.hostTime;
            atomic_fetch_add(&gValidTimestamps, 1);
        }
    }
    atomic_fetch_sub(&gReaderInFlight, 1);
}
static bool EngineInputIsPinned(AudioUnit unit) {
    AudioDeviceID current = 0; UInt32 size = sizeof(current);
    return unit && AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr &&
        size == sizeof(current) && current == gVisible && Resolve(@OSVA_VISIBLE_INPUT_DEVICE_UID) == current;
}
static bool EngineIsInputOnly(AudioUnit unit, AVAudioInputNode *input) {
    UInt32 enabledInput = 0, enabledOutput = 1, size = sizeof(enabledInput);
    if (!unit || input.isVoiceProcessingEnabled ||
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabledInput, &size) != noErr ||
        size != sizeof(enabledInput) || enabledInput != 1) return false;
    size = sizeof(enabledOutput);
    return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabledOutput, &size) == noErr &&
        size == sizeof(enabledOutput) && enabledOutput == 0;
}
static OSStatus EngineFormat(AudioUnit unit, AudioUnitScope scope, AudioStreamBasicDescription *format) {
    UInt32 size = sizeof(*format);
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 1, format, &size);
    return status == noErr && size != sizeof(*format) ? kAudioHardwareBadPropertySizeError : status;
}
static bool MonoFloatFormat(const AudioStreamBasicDescription *format) {
    const AudioFormatFlags flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    return format->mSampleRate == 48000 && format->mChannelsPerFrame == 1 && format->mFormatID == kAudioFormatLinearPCM &&
        (format->mFormatFlags == flags || format->mFormatFlags == (flags | kAudioFormatFlagIsNonInterleaved)) &&
        format->mBitsPerChannel == 32 && format->mBytesPerFrame == 4 && format->mBytesPerPacket == 4 && format->mFramesPerPacket == 1;
}
static bool EngineFormatsMatch(AudioUnit unit, AVAudioInputNode *input) {
    AVAudioFormat *node = [input outputFormatForBus:0];
    AudioStreamBasicDescription hardware = {0}, client = {0};
    return node && node.sampleRate == 48000 && node.channelCount == 1 && node.commonFormat == AVAudioPCMFormatFloat32 &&
        EngineFormat(unit, kAudioUnitScope_Input, &hardware) == noErr && MonoFloatFormat(&hardware) &&
        EngineFormat(unit, kAudioUnitScope_Output, &client) == noErr && MonoFloatFormat(&client);
}
static int64_t ReportedRate(Float64 rate) {
    return isfinite(rate) && rate >= 0 && rate <= 384000 ? (int64_t)rate : -1;
}
static bool WaitCommandOnFD(int fd, char *line, size_t capacity, unsigned seconds) {
    if (gCancelled || atomic_load(&gGuardFailed) || fd < 0 || capacity < 2 || seconds == 0) return false;
    uint64_t deadline = Now() + (uint64_t)seconds * UINT64_C(1000000000);
    size_t used = 0;
    line[0] = '\0';
    while (!gCancelled && !atomic_load(&gGuardFailed)) {
        uint64_t current = Now();
        if (current >= deadline) return false;
        uint64_t remainingMS = (deadline - current + UINT64_C(999999)) / UINT64_C(1000000);
        struct pollfd descriptor = {fd, POLLIN, 0};
        int result = poll(&descriptor, 1, (int)(remainingMS > 100 ? 100 : remainingMS));
        if (gCancelled || atomic_load(&gGuardFailed)) return false;
        if (result < 0) { if (errno == EINTR) continue; return false; }
        if (result == 0) continue;
        if (!(descriptor.revents & POLLIN)) return false;
        // This descriptor has one consumer. Read only a ready byte, never block
        // in stdio awaiting the rest of a partial supervisor command.
        char byte = '\0';
        ssize_t count = read(fd, &byte, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count != 1 || byte == '\0') return false;
        if (gCancelled || atomic_load(&gGuardFailed)) return false;
        if (used == capacity - 1) return false;
        line[used++] = byte;
        line[used] = '\0';
        if (byte == '\n') return true;
    }
    return false;
}
static bool WaitCommand(char *line, size_t capacity, unsigned seconds) {
    return WaitCommandOnFD(STDIN_FILENO, line, capacity, seconds);
}
static void *CancelCommandTestWait(void *context) {
    pthread_t target = *(pthread_t *)context;
    usleep(20000);
    (void)pthread_kill(target, SIGTERM);
    return NULL;
}
static int TestCommandCancellation(void) {
    // Offline: anonymous pipes, one retained thread and this process's signal only.
    int descriptors[2];
    if (pipe(descriptors) != 0) return 1;
    char line[128]; unsigned checks = 0; bool passed = true;
    void (*priorHandler)(int) = signal(SIGTERM, Cancel);
    uint64_t started = Now();
    gCancelled = 1;
    passed = !WaitCommandOnFD(descriptors[0], line, sizeof(line), 10) && Now() - started < UINT64_C(250000000);
    checks += passed;
    gCancelled = 0;
    atomic_store(&gGuardFailed, true);
    started = Now();
    bool guarded = !WaitCommandOnFD(descriptors[0], line, sizeof(line), 10) && Now() - started < UINT64_C(250000000);
    passed &= guarded; checks += guarded;
    atomic_store(&gGuardFailed, false);
    const char command[] = "start 123\n";
    bool complete = write(descriptors[1], command, sizeof(command) - 1) == sizeof(command) - 1 &&
        WaitCommandOnFD(descriptors[0], line, sizeof(line), 1) && strcmp(line, command) == 0;
    passed &= complete; checks += complete;
    bool partial = write(descriptors[1], "st", 2) == 2;
    pthread_t testThread, target = pthread_self();
    atomic_store(&gGate, true);
    if (partial && pthread_create(&testThread, NULL, CancelCommandTestWait, &target) == 0) {
        started = Now();
        partial = !WaitCommandOnFD(descriptors[0], line, sizeof(line), 10) && Now() - started < UINT64_C(250000000);
        pthread_join(testThread, NULL);
        partial &= gCancelled != 0 && !atomic_load(&gGate);
    } else partial = false;
    passed &= partial; checks += partial;
    atomic_store(&gGate, false);
    gCancelled = 0;
    close(descriptors[1]);
    bool eof = !WaitCommandOnFD(descriptors[0], line, sizeof(line), 1);
    passed &= eof; checks += eof;
    close(descriptors[0]);
    signal(SIGTERM, priorHandler);
    Event("checked", "offline_command_cancellation_contracts", checks);
    return passed ? 0 : 1;
}
static void Observe(unsigned milliseconds) {
    uint64_t deadline = Now() + (uint64_t)milliseconds * 1000000;
    while (!gCancelled && !atomic_load(&gGuardFailed) && Now() < deadline) usleep(10000);
}
static int Reader(void) {
    Event("ready", "reader", 0);
    char command[128]; int other = 0; char extra = 0;
    if (!WaitCommand(command, sizeof(command), 10) || sscanf(command, "start %d %c", &other, &extra) != 1 || !ExpectedProcess(other)) return 65;
    gOtherPID = other;
    if (!RuntimeMatches(false)) return 65;
    pthread_t monitor;
    if (pthread_create(&monitor, NULL, Monitor, NULL) != 0) return 70;
    AudioQueueRef queue = NULL;
    AudioStreamBasicDescription format = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 4, 1, 4, 1, 32, 0};
    bool attempted = false;
    OSStatus status = AudioQueueNewInput(&format, ReaderIO, NULL, NULL, NULL, 0, &queue);
    if (status == noErr) {
        CFStringRef uid = CFSTR(OSVA_VISIBLE_INPUT_DEVICE_UID);
        status = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
        CFStringRef actual = NULL; UInt32 size = sizeof(actual);
        if (status == noErr) status = AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &actual, &size);
        if (status == noErr && (!actual || !CFEqual(actual, uid))) status = kAudio_ParamError;
        if (actual) CFRelease(actual);
        for (unsigned i = 0; status == noErr && i < 3; ++i) {
            AudioQueueBufferRef buffer = NULL;
            status = AudioQueueAllocateBuffer(queue, 1920, &buffer);
            if (status == noErr) status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        }
        if (status == noErr && RuntimeMatches(false)) {
            atomic_store(&gGate, true);
            attempted = true;
            Event("begin", "input_start", 0);
            status = AudioQueueStart(queue, NULL);
            Event("end", "input_start", status);
            if (status == noErr) {
                CFStringRef after = NULL; UInt32 afterSize = sizeof(after);
                status = AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &after, &afterSize);
                if (status == noErr && (!after || !CFEqual(after, uid))) status = kAudio_ParamError;
                if (after) CFRelease(after);
                Event("checked", "input_uid_after_start", status == noErr ? 1 : 0);
                if (status == noErr) Observe(2000);
            }
        } else if (status == noErr) status = kAudio_ParamError;
    }
    Event("measurement", "input_callbacks", (int64_t)atomic_load(&gCallbacks));
    Event("measurement", "input_frames", (int64_t)atomic_load(&gFrames));
    Event("measurement", "input_valid_timestamps", (int64_t)atomic_load(&gValidTimestamps));
    Event("measurement", "input_advancing_timestamps", (int64_t)atomic_load(&gAdvancingTimestamps));
    Event("measurement", "input_callback_error", atomic_load(&gCallbackError));
    Event("measurement", "foreign_output_observed", atomic_load(&gForeignOutputObserved) ? 1 : 0);
    Event("measurement", "own_output_observed", atomic_load(&gOwnOutputObserved) ? 1 : 0);
    Event("measurement", "peer_output_observed", atomic_load(&gPeerOutputObserved) ? 1 : 0);
    // A deadline signal may have arrived during the synchronous start call.
    // Do not enter another command wait once that supervisor has cancelled us.
    if (!gCancelled && !atomic_load(&gGuardFailed)) {
        Event("ready", "reader_teardown", 0);
        (void)WaitCommand(command, sizeof(command), 10);
    }
    atomic_store(&gGate, false);
    atomic_store(&gMonitorDone, true);
    pthread_join(monitor, NULL);
    bool drained = true;
    if (queue) {
        if (attempted && AudioQueueStop(queue, true) != noErr) drained = false;
        if (AudioQueueDispose(queue, true) != noErr) drained = false;
    }
    Event("teardown", "reader", drained && SelectorsMatch(false) ? 1 : 0);
    return status == noErr && drained && !atomic_load(&gGuardFailed) && atomic_load(&gCallbackError) == noErr ? 0 : 1;
}
static int AlignedReader(void) {
    Event("checked", "production_aligned", 1);
    Event("ready", "reader", 0);
    char command[128]; int other = 0; char extra = 0;
    if (!WaitCommand(command, sizeof(command), 10) || sscanf(command, "start %d %c", &other, &extra) != 1 || !ExpectedProcess(other)) return 65;
    gOtherPID = other;
    if (!RuntimeMatches(false)) return 65;
    pthread_t monitor;
    if (pthread_create(&monitor, NULL, Monitor, NULL) != 0) return 70;
    // The supervisor deadline begins before inputNode or device setup can block.
    Event("begin", "input_start", 0);
    Event("begin", "input_setup", 0);
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AudioUnit unit = input.audioUnit;
    bool installedTap = false, attempted = false;
    OSStatus setupStatus = unit ? noErr : kAudio_ParamError;
    UInt32 enabled = 1, disabled = 0;
    if (setupStatus == noErr) setupStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
    if (setupStatus == noErr) setupStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, sizeof(disabled));
    if (setupStatus == noErr) setupStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &gVisible, sizeof(gVisible));
    bool pinned = setupStatus == noErr && EngineInputIsPinned(unit);
    bool inputOnly = setupStatus == noErr && EngineIsInputOnly(unit, input);
    Event("checked", "input_uid_before_start", pinned ? 1 : 0);
    Event("checked", "input_voice_processing_disabled", inputOnly ? 1 : 0);
    if (!pinned || !inputOnly) setupStatus = kAudio_ParamError;
    AVAudioFormat *observed = setupStatus == noErr ? [input outputFormatForBus:0] : nil;
    AudioStreamBasicDescription hardware = {0}, client = {0};
    OSStatus hardwareStatus = setupStatus == noErr ? EngineFormat(unit, kAudioUnitScope_Input, &hardware) : setupStatus;
    OSStatus clientStatus = setupStatus == noErr ? EngineFormat(unit, kAudioUnitScope_Output, &client) : setupStatus;
    Event("checked", "input_node_format_rate", observed ? ReportedRate(observed.sampleRate) : -1);
    Event("checked", "input_node_format_channels", observed ? observed.channelCount : -1);
    Event("checked", "input_node_format_common", observed ? observed.commonFormat : -1);
    Event("checked", "input_hardware_format_status", hardwareStatus);
    Event("checked", "input_hardware_format_rate", ReportedRate(hardware.mSampleRate));
    Event("checked", "input_hardware_format_channels", hardware.mChannelsPerFrame);
    Event("checked", "input_hardware_format_flags", hardware.mFormatFlags);
    Event("checked", "input_unit_format_status", clientStatus);
    Event("checked", "input_unit_format_rate", ReportedRate(client.mSampleRate));
    Event("checked", "input_unit_format_channels", client.mChannelsPerFrame);
    Event("checked", "input_unit_format_flags", client.mFormatFlags);
    if (setupStatus == noErr && (hardwareStatus != noErr || !MonoFloatFormat(&hardware) || clientStatus != noErr)) setupStatus = kAudio_ParamError;
    // installTap's format argument sets an unconnected node output bus through
    // AVAudioEngine. Do not modify its underlying AudioUnit stream format directly.
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000 channels:1 interleaved:NO];
    if (!format) setupStatus = kAudio_ParamError;
    if (setupStatus == noErr) {
        [input installTapOnBus:0 bufferSize:4800 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *time) { EngineReaderIO(buffer, time); }];
        installedTap = true;
        [engine prepare];
        bool formatsMatch = EngineFormatsMatch(unit, input);
        Event("checked", "input_format_after_prepare", formatsMatch ? 1 : 0);
        if (!formatsMatch || atomic_load(&gGuardFailed) || !RuntimeMatches(false) || !EngineInputIsPinned(unit) || !EngineIsInputOnly(unit, input)) setupStatus = kAudio_ParamError;
    }
    Event("end", "input_setup", setupStatus);
    int64_t status = setupStatus;
    int errorDomain = setupStatus == noErr ? 0 : 1;
    if (setupStatus == noErr) {
        atomic_store(&gGate, true);
        if (atomic_load(&gGuardFailed) || !RuntimeMatches(false)) {
            atomic_store(&gGate, false);
            status = kAudio_ParamError;
            errorDomain = 1;
        }
    }
    if (status == noErr) {
        attempted = true;
        NSError *error = nil;
        Event("begin", "input_engine_start", 0);
        BOOL started = [engine startAndReturnError:&error];
        status = started ? 0 : (error ? (int64_t)error.code : kAudio_ParamError);
        errorDomain = started ? 0 : ([error.domain isEqual:NSOSStatusErrorDomain] ? 1 :
            ([error.domain isEqual:NSPOSIXErrorDomain] ? 2 : ([error.domain isEqual:AVFoundationErrorDomain] ? 3 : 4)));
        Event("end", "input_engine_start", status);
        if (!started && status == 0) { status = kAudio_ParamError; errorDomain = 4; }
    }
    Event("checked", "input_error_domain", errorDomain);
    Event("end", "input_start", status);
    if (status == 0) {
        pinned = EngineInputIsPinned(unit);
        inputOnly = EngineIsInputOnly(unit, input);
        Event("checked", "input_uid_after_start", pinned ? 1 : 0);
        Event("checked", "input_only_after_start", inputOnly ? 1 : 0);
        bool formatsMatch = EngineFormatsMatch(unit, input);
        Event("checked", "input_format_after_start", formatsMatch ? 1 : 0);
        if (!pinned || !inputOnly || !formatsMatch || !engine.running || !RuntimeMatches(false)) status = kAudio_ParamError;
        else Observe(2000);
    }
    Event("measurement", "input_callbacks", (int64_t)atomic_load(&gCallbacks));
    Event("measurement", "input_frames", (int64_t)atomic_load(&gFrames));
    Event("measurement", "input_valid_timestamps", (int64_t)atomic_load(&gValidTimestamps));
    Event("measurement", "input_advancing_timestamps", (int64_t)atomic_load(&gAdvancingTimestamps));
    Event("measurement", "input_callback_error", atomic_load(&gCallbackError));
    Event("measurement", "foreign_output_observed", atomic_load(&gForeignOutputObserved) ? 1 : 0);
    Event("measurement", "own_output_observed", atomic_load(&gOwnOutputObserved) ? 1 : 0);
    Event("measurement", "peer_output_observed", atomic_load(&gPeerOutputObserved) ? 1 : 0);
    if (!gCancelled && !atomic_load(&gGuardFailed)) {
        Event("ready", "reader_teardown", 0);
        (void)WaitCommand(command, sizeof(command), 10);
    }
    atomic_store(&gGate, false);
    atomic_store(&gMonitorDone, true);
    pthread_join(monitor, NULL);
    if (attempted) [engine stop];
    if (installedTap) [input removeTapOnBus:0];
    [engine reset];
    bool drained = !engine.running;
    input = nil;
    engine = nil;
    uint64_t retiredInvocations = atomic_load(&gReaderInvocations);
    // stop/removeTap have returned. A subsequent callback makes retirement unproved.
    usleep(100000);
    drained = drained && atomic_load(&gReaderInFlight) == 0 && atomic_load(&gReaderInvocations) == retiredInvocations;
    Event("checked", "input_callbacks_drained", drained ? 1 : 0);
    Event("teardown", "reader", drained && SelectorsMatch(false) ? 1 : 0);
    return status == 0 && drained && !atomic_load(&gGuardFailed) && atomic_load(&gCallbackError) == noErr ? 0 : 1;
}
static int Owner(bool autoStart) {
    AudioDeviceIOProcID writer = NULL, aggregateIO = NULL;
    AudioQueueRef writerQueue = NULL;
    AudioObjectID tap = 0, aggregate = 0;
    bool writerAttempted = false, aggregateAttempted = false;
    pthread_t monitor;
    if (pthread_create(&monitor, NULL, Monitor, NULL) != 0) return 70;
    OSStatus status = noErr;
    if (gProductionAligned) Event("checked", "production_aligned", 1);
    else {
        status = AudioDeviceCreateIOProcID(gHidden, SilentIO, (void *)(uintptr_t)1, &writer);
        if (status == noErr && RuntimeMatches(false)) {
            writerAttempted = true;
            status = AudioDeviceStart(gHidden, writer);
        } else if (status == noErr) status = kAudio_ParamError;
        Event("end", "writer_start", status);
    }
    if (status == noErr) {
        NSArray<NSNumber *> *processes = ObjectList(kAudioHardwarePropertyProcessObjectList);
        NSMutableArray<NSNumber *> *excluded = [NSMutableArray array];
        bool foundSelf = false, foundReader = false;
        for (NSNumber *object in processes) {
            pid_t pid = 0;
            if (Read(object.unsignedIntValue, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid, sizeof(pid)) != noErr) { status = kAudio_ParamError; break; }
            if (pid == getpid()) { [excluded addObject:object]; foundSelf = true; }
            if (pid == gOtherPID) { if (!gProductionAligned) [excluded addObject:object]; foundReader = true; }
        }
        if (!processes || !foundSelf || !foundReader) status = kAudio_ParamError;
        if (status == noErr) {
            CATapDescription *description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excluded];
            description.name = @"Beluga Tap Startup Probe";
            description.UUID = [[NSUUID alloc] initWithUUIDString:gRunID];
            description.private = YES; description.exclusive = YES; description.muteBehavior = CATapUnmuted;
            status = AudioHardwareCreateProcessTap(description, &tap);
            if (status == noErr && gProductionAligned) {
                CFTypeRef raw = NULL;
                status = Read(tap, kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal, &raw, sizeof(raw));
                CATapDescription *actual = CFBridgingRelease(raw);
                bool matches = status == noErr && [actual isKindOfClass:CATapDescription.class] &&
                    actual.isPrivate && actual.isExclusive && actual.isMuted == CATapUnmuted &&
                    [actual.UUID.UUIDString isEqual:gRunID] && actual.processes.count == excluded.count &&
                    [[NSSet setWithArray:actual.processes] isEqual:[NSSet setWithArray:excluded]];
                Event("checked", "reader_included", matches ? 1 : 0);
                if (!matches) status = kAudio_ParamError;
            }
        }
    }
    if (status == noErr) {
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey: @"Beluga Tap Startup Probe",
            @kAudioAggregateDeviceUIDKey: [@"com.elamin.opensteamer.TapStartupProbe." stringByAppendingString:gRunID],
            @kAudioAggregateDeviceMainSubDeviceKey: gClockUID,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: gClockUID}],
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: gRunID, @kAudioSubTapDriftCompensationKey: @YES}],
            @kAudioAggregateDeviceTapAutoStartKey: @(autoStart),
            @kAudioAggregateDeviceIsStackedKey: @NO,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &aggregate);
        CFDictionaryRef actual = NULL;
        if (status == noErr) status = Read(aggregate, kAudioAggregateDevicePropertyComposition, kAudioObjectPropertyScopeGlobal, &actual, sizeof(actual));
        NSDictionary *readback = CFBridgingRelease(actual);
        if (status == noErr && (![readback[@kAudioAggregateDeviceTapAutoStartKey] isEqual:@(autoStart)] ||
            ![readback[@kAudioAggregateDeviceMainSubDeviceKey] isEqual:gClockUID] ||
            ![StringProperty(tap, kAudioTapPropertyUID) isEqual:gRunID])) status = kAudio_ParamError;
        Event("checked", "tap_auto_start_readback", status == noErr ? (autoStart ? 1 : 0) : -1);
    }
    if (status == noErr) status = AudioDeviceCreateIOProcID(aggregate, SilentIO, (void *)(uintptr_t)2, &aggregateIO);
    if (status == noErr && RuntimeMatches(false)) {
        atomic_store(&gGate, true);
        aggregateAttempted = true;
        Event("begin", "tap_start", autoStart ? 1 : 0);
        status = AudioDeviceStart(aggregate, aggregateIO);
        Event("end", "tap_start", status);
        if (status == noErr && gProductionAligned &&
            (atomic_load(&gGuardFailed) || !RuntimeMatches(false) || !atomic_load(&gGate))) status = kAudio_ParamError;
        if (status == noErr && gProductionAligned) {
            // Match production order: a returned tap start, then the hidden AudioQueue.
            Event("begin", "writer_start", 0);
            AudioStreamBasicDescription format = {48000, kAudioFormatLinearPCM,
                kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 2, 1, 2, 1, 16, 0};
            status = AudioQueueNewOutput(&format, SilentWriterQueueIO, NULL, NULL, NULL, 0, &writerQueue);
            CFStringRef uid = CFSTR(OSVA_HIDDEN_WRITER_DEVICE_UID);
            if (status == noErr) status = AudioQueueSetProperty(writerQueue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
            bool pinned = status == noErr && QueueIsPinned(writerQueue, @OSVA_HIDDEN_WRITER_DEVICE_UID, gHidden);
            Event("checked", "writer_uid_before_start", pinned ? 1 : 0);
            if (!pinned) status = kAudio_ParamError;
            for (unsigned i = 0; status == noErr && i < 3; ++i) {
                AudioQueueBufferRef buffer = NULL;
                status = AudioQueueAllocateBuffer(writerQueue, 960, &buffer);
                if (status == noErr) {
                    memset(buffer->mAudioData, 0, buffer->mAudioDataBytesCapacity);
                    buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
                    if (RuntimeMatches(false) && atomic_load(&gGate)) status = AudioQueueEnqueueBuffer(writerQueue, buffer, 0, NULL);
                    else status = kAudio_ParamError;
                }
            }
            if (status == noErr && RuntimeMatches(false) && atomic_load(&gGate)) {
                writerAttempted = true;
                status = AudioQueueStart(writerQueue, NULL);
            } else if (status == noErr) status = kAudio_ParamError;
            Event("end", "writer_start", status);
            if (status == noErr) {
                pinned = QueueIsPinned(writerQueue, @OSVA_HIDDEN_WRITER_DEVICE_UID, gHidden);
                Event("checked", "writer_uid_after_start", pinned ? 1 : 0);
                bool formatMatches = WriterFormatMatches(writerQueue);
                Event("checked", "writer_format_after_start", formatMatches ? 1 : 0);
                if (!pinned || !formatMatches) status = kAudio_ParamError;
            }
            if (status == noErr) {
                uint64_t deadline = Now() + UINT64_C(2000000000);
                while (!gCancelled && !atomic_load(&gGuardFailed) && atomic_load(&gCallbackError) == noErr &&
                    atomic_load(&gWriterCallbacks) < 2 && Now() < deadline) usleep(10000);
                if (atomic_load(&gWriterCallbacks) < 2 || atomic_load(&gCallbackError) != noErr ||
                    !RuntimeMatches(false) || !atomic_load(&gGate)) status = kAudio_ParamError;
                else {
                    Event("ready", "production_forwarding", 1);
                    char command[128];
                    if (WaitCommand(command, sizeof(command), 30)) {
                        if (strcmp(command, "retire-tap\n") != 0) status = kAudio_ParamError;
                        else {
                            Event("begin", "tap_retirement", 0);
                            uint64_t writerBefore = atomic_load(&gWriterCallbacks);
                            Event("measurement", "writer_callbacks_before_tap_retirement", (int64_t)writerBefore);
                            bool writerPinned = QueueIsPinned(writerQueue, @OSVA_HIDDEN_WRITER_DEVICE_UID, gHidden);
                            bool writerFormat = WriterFormatMatches(writerQueue);
                            Event("checked", "writer_uid_before_tap_retirement", writerPinned ? 1 : 0);
                            Event("checked", "writer_format_before_tap_retirement", writerFormat ? 1 : 0);
                            NSString *aggregateUID = [@"com.elamin.opensteamer.TapStartupProbe." stringByAppendingString:gRunID];
                            if (!writerPinned || !writerFormat || !atomic_load(&gGate) || atomic_load(&gGuardFailed) ||
                                !RuntimeMatches(false) || !aggregateIO || !aggregate || !tap ||
                                ![StringProperty(aggregate, kAudioDevicePropertyDeviceUID) isEqual:aggregateUID] ||
                                ![StringProperty(tap, kAudioTapPropertyUID) isEqual:gRunID]) status = kAudio_ParamError;
                            // Retire only this owner's tap path. The existing writer queue
                            // and its admission gate remain running throughout the intervention.
                            if (status == noErr) {
                                status = AudioDeviceStop(aggregate, aggregateIO);
                                if (status == noErr) aggregateAttempted = false;
                            }
                            if (status == noErr) {
                                status = AudioDeviceDestroyIOProcID(aggregate, aggregateIO);
                                if (status == noErr) aggregateIO = NULL;
                            }
                            if (status == noErr) {
                                status = AudioHardwareDestroyAggregateDevice(aggregate);
                                if (status == noErr) aggregate = 0;
                            }
                            if (status == noErr) {
                                status = AudioHardwareDestroyProcessTap(tap);
                                if (status == noErr) tap = 0;
                            }
                            Event("end", "tap_retirement", status);
                            if (status == noErr) Observe(200);
                            uint64_t writerAfter = atomic_load(&gWriterCallbacks);
                            writerPinned = QueueIsPinned(writerQueue, @OSVA_HIDDEN_WRITER_DEVICE_UID, gHidden);
                            writerFormat = WriterFormatMatches(writerQueue);
                            Event("measurement", "writer_callbacks_after_tap_retirement", (int64_t)writerAfter);
                            Event("checked", "writer_uid_after_tap_retirement", writerPinned ? 1 : 0);
                            Event("checked", "writer_format_after_tap_retirement", writerFormat ? 1 : 0);
                            bool writerContinued = status == noErr && writerAfter >= writerBefore && writerAfter - writerBefore >= 2 &&
                                writerPinned && writerFormat && atomic_load(&gGate) && atomic_load(&gCallbackError) == noErr &&
                                !atomic_load(&gGuardFailed) && RuntimeMatches(false);
                            Event("checked", "writer_continued_during_tap_retirement", writerContinued ? 1 : 0);
                            bool retired = !aggregateIO && !aggregate && !tap && writerContinued;
                            Event("teardown", "tap_only", retired ? 1 : 0);
                            if (!retired) status = kAudio_ParamError;
                            else if (WaitCommand(command, sizeof(command), 10)) status = kAudio_ParamError;
                        }
                    }
                }
            }
        } else if (status == noErr) Observe(20000);
    } else if (status == noErr) status = kAudio_ParamError;
    atomic_store(&gGate, false);
    atomic_store(&gMonitorDone, true);
    pthread_join(monitor, NULL);
    Event("measurement", "writer_callbacks", (int64_t)atomic_load(&gWriterCallbacks));
    Event("measurement", "tap_callbacks", (int64_t)atomic_load(&gTapCallbacks));
    if (gProductionAligned) Event("measurement", "writer_callback_error", atomic_load(&gCallbackError));
    Event("measurement", "foreign_output_observed", atomic_load(&gForeignOutputObserved) ? 1 : 0);
    Event("measurement", "own_output_observed", atomic_load(&gOwnOutputObserved) ? 1 : 0);
    Event("measurement", "peer_output_observed", atomic_load(&gPeerOutputObserved) ? 1 : 0);
    bool drained = true;
    if (aggregateIO) {
        if (aggregateAttempted && AudioDeviceStop(aggregate, aggregateIO) != noErr) drained = false;
        if (AudioDeviceDestroyIOProcID(aggregate, aggregateIO) != noErr) drained = false;
    }
    if (aggregate && AudioHardwareDestroyAggregateDevice(aggregate) != noErr) drained = false;
    if (tap && AudioHardwareDestroyProcessTap(tap) != noErr) drained = false;
    if (writer) {
        if (writerAttempted && AudioDeviceStop(gHidden, writer) != noErr) drained = false;
        if (AudioDeviceDestroyIOProcID(gHidden, writer) != noErr) drained = false;
    }
    if (writerQueue) {
        if (writerAttempted && AudioQueueStop(writerQueue, true) != noErr) drained = false;
        if (AudioQueueDispose(writerQueue, true) != noErr) drained = false;
    }
    Event("teardown", "owner", drained && SelectorsMatch(false) ? 1 : 0);
    return status == noErr && drained && !atomic_load(&gGuardFailed) && atomic_load(&gCallbackError) == noErr ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--output-activity-check") == 0) return OutputActivityCheck();
        if (argc == 2 && strcmp(argv[1], "--offline-output-classifier-test") == 0) return TestOutputClassification();
        if (argc == 2 && strcmp(argv[1], "--offline-host-classifier-test") == 0) return TestPublicProcessClass();
        if (argc == 2 && strcmp(argv[1], "--offline-command-cancellation-test") == 0) return TestCommandCancellation();
        if (argc == 2 && strcmp(argv[1], "--host-scan-diagnostic") == 0) return HostScanDiagnostic();
        if ((argc == 2 || (argc == 4 && strcmp(argv[2], "--host-pid") == 0)) && strcmp(argv[1], "--permission-check") == 0) {
            // Read-only: no tap, queue, device I/O, requestAccess, or TCC mutation.
            Event("checked", "microphone_authorization_status", [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]);
            Event("checked", "diagnostic_bundle_identity", [[NSBundle mainBundle].bundleIdentifier isEqual:@"com.elamin.opensteamer.TapStartupDiagnostic"] ? 1 : 0);
            Event("gate", "system_audio_authorization_unverifiable_without_prompt", 1);
            if (argc == 4) {
                char *end = NULL; errno = 0;
                long host = strtol(argv[3], &end, 10);
                char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
                struct proc_bsdinfo info = {0};
                if (errno || !end || *end || host <= 1 || host > INT_MAX ||
                    proc_pidpath((pid_t)host, path, sizeof(path)) <= 0 || strcmp(path, kHostPath) ||
                    proc_pidinfo((pid_t)host, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
                    Event("guard_failed", "host_identity", 1); return 65;
                }
                Event("checked", "observed_host_pid", host);
                Event("checked", "observed_host_start_seconds", (int64_t)info.pbi_start_tvsec);
                Event("checked", "observed_host_start_microseconds", (int64_t)info.pbi_start_tvusec);
            }
            return 0;
        }
        // Invalid/incomplete invocations return before any Core Audio API.
        if (argc < 2 || strcmp(argv[1], "--live-opt-in") != 0 || (argc - 2) % 2 != 0) return 64;
        NSMutableDictionary<NSString *, NSString *> *args = [NSMutableDictionary dictionary];
        NSSet *keys = [NSSet setWithArray:@[@"--mode", @"--supervisor-pid", @"--driver-sha256", @"--driver-instance", @"--clock-uid", @"--input-uid", @"--output-uid", @"--system-output-uid", @"--run-id", @"--other-pid", @"--tap-auto-start", @"--host-pid", @"--host-start-seconds", @"--host-start-microseconds", @"--host-sha256", @"--audio-capture-permission-confirmed", @"--production-aligned"]];
        for (int i = 2; i < argc; i += 2) {
            NSString *key = @(argv[i]), *value = @(argv[i + 1]);
            if (![keys containsObject:key] || args[key] || value.length == 0 || value.length > 512) return 64;
            args[key] = value;
        }
        if (!args[@"--production-aligned"]) args[@"--production-aligned"] = @"0";
        if (args.count != keys.count || ![@[@"0", @"1"] containsObject:args[@"--production-aligned"]]) return 64;
        gProductionAligned = [args[@"--production-aligned"] isEqual:@"1"];
        NSRegularExpression *digits = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+$" options:0 error:nil];
        for (NSString *key in @[@"--supervisor-pid", @"--driver-instance", @"--other-pid", @"--host-pid", @"--host-start-seconds", @"--host-start-microseconds"]) {
            if ([digits numberOfMatchesInString:args[key] options:0 range:NSMakeRange(0, [args[key] length])] != 1) return 64;
        }
        if (![args[@"--audio-capture-permission-confirmed"] isEqual:@"already-authorized"] ||
            ![@[@"owner", @"reader", @"check"] containsObject:args[@"--mode"]] || ![@[@"0", @"1"] containsObject:args[@"--tap-auto-start"]] ||
            ![[NSUUID alloc] initWithUUIDString:args[@"--run-id"]] || args[@"--driver-sha256"].length != 64) return 64;
        gSupervisorPID = args[@"--supervisor-pid"].intValue;
        gOtherPID = args[@"--other-pid"].intValue;
        gHostPID = args[@"--host-pid"].intValue;
        gHostStartSeconds = strtoull(args[@"--host-start-seconds"].UTF8String, NULL, 10);
        gHostStartMicroseconds = strtoull(args[@"--host-start-microseconds"].UTF8String, NULL, 10);
        gDriverInstance = strtoull(args[@"--driver-instance"].UTF8String, NULL, 10);
        if (gSupervisorPID <= 1 || getppid() != gSupervisorPID || !gDriverInstance ||
            proc_pidpath(getpid(), gExecutablePath, sizeof(gExecutablePath)) <= 0) return 64;
        // Read-only TCC check; this diagnostic never requests microphone permission.
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
            Event("guard_failed", "microphone_permission", 1); return 65;
        }
        gRunID = args[@"--run-id"]; gClockUID = args[@"--clock-uid"];
        gDefaultUIDs[0] = args[@"--input-uid"]; gDefaultUIDs[1] = args[@"--output-uid"]; gDefaultUIDs[2] = args[@"--system-output-uid"];
        signal(SIGINT, Cancel); signal(SIGTERM, Cancel); signal(SIGHUP, Cancel);
        atomic_store(&gGate, false);
        if (!SetupGuards(args)) { Event("guard_failed", atomic_load(&gFailureStage), 1); RemoveGuards(); return 65; }
        int result = 0;
        if ([args[@"--mode"] isEqual:@"check"]) Event("checked", "idle", 1);
        else if ([args[@"--mode"] isEqual:@"reader"]) result = gProductionAligned ? AlignedReader() : Reader();
        else result = gOtherPID > 1 ? Owner([args[@"--tap-auto-start"] isEqual:@"1"]) : 64;
        bool finalSelectors = SelectorsMatch(false);
        bool removed = RemoveGuards();
        Event("final", "selectors_unchanged", finalSelectors && removed ? 1 : 0);
        return finalSelectors && removed ? result : 65;
    }
}
