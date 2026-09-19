# Now Playing thumbnails

The native Chrome/YouTube adapter attaches an optional, validated video identifier
to the existing current-item metadata. The iPhone retrieves the corresponding
thumbnail independently from YouTube's fixed HTTPS image host. No image bytes are
sent through the ordered 4 KiB control channel, and image retrieval never delays
metadata publication or media commands.

This first implementation covers native Chrome/YouTube only. Native Music and the
optional browser-extension adapter continue without artwork. Local Music track IDs
are not public artwork identifiers; the app does not guess images using song titles
or upload library metadata to a search service.

## Resource and privacy boundaries

- Image requests use an ephemeral session without cookies, saved credentials,
  persistent cache, or redirects. The iPhone's network address and requested video
  ID are visible to YouTube's image service, independently of the Mac stream.
- Each request has an 8-second request timeout and 10-second resource timeout.
  The body is capped while streaming at 256 KiB. JPEG/PNG images must be single-frame,
  at most 4 megapixels and 4096 pixels per axis; decoding downsamples to 512 pixels.
- The presentation keeps at most four decoded thumbnails in memory, expires cached
  entries after five minutes, and clears them when the owner or connection changes.
  There is one current load and at most one retry per presentation. New targets
  cancel superseded requests; ordinary elapsed-time updates do not restart loading.
- Owner, transport negotiation, media context, thumbnail reference, and local request
  generation must still match when a result arrives. A missing or failed image leaves
  controls usable. Music takeover and explicit metadata clearing remove old artwork.

## Compatibility and verification

The reference is advisory. Old clients ignore its extra metadata field; new clients
accept old metadata without it. Malformed or unknown artwork is discarded without
discarding otherwise valid playback controls. Existing control negotiation, wire
limits, command deduplication, and playback/privacy policy remain unchanged.

Focused shared/Mac tests exercise source binding and old/new wire compatibility.
Hosted iOS tests exercise the actual MediaPlayer dictionary, asynchronous source
replacement, late completions, image decoding, and bounded URLSession loading.
Source tests and Simulator presentation are not Lock Screen proof: a deployed host
and the new iPhone TestFlight build must still show artwork and preserve all available
controls through track replacement, Pause/Play, and reconnection.
