"""Offline lifecycle tests: fake the device transport, never import its runtime or call a phone."""

import asyncio
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


HELPER_PATH = Path(__file__).resolve().parents[1] / "iphone15-dev-power-assertion.py"


class PowerAssertionLifecycleTests(unittest.TestCase):
    def run_helper(self, scenario="normal"):
        spec = importlib.util.spec_from_file_location("power_assertion_under_test", HELPER_PATH)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        state = SimpleNamespace(
            elapsed=0.0, owner=123, stop=False, services=[], events=[], statuses=[], timeouts=[]
        )
        rsd = SimpleNamespace(
            udid="wrong" if scenario == "wrong_device" else helper.EXACT_HARDWARE_UDID
        )

        class Tunnel:
            def __init__(self, serial):
                self.serial = serial
                state.events.append(("tunnel_create", serial))

            async def aopen(self):
                state.events.append(("tunnel_open", self.serial))
                return rsd

            async def aclose(self):
                state.events.append(("tunnel_close", self.serial))
                if scenario == "tunnel_close_failure":
                    raise RuntimeError("fixture tunnel close failure")

        class Assertion:
            def __init__(self, service):
                self.service = service

            async def __aenter__(self):
                service = self.service
                service.commands += 1
                if service.commands != 1:
                    raise ConnectionResetError("fixture agent permits one command per connection")
                state.events.append(("acquire", service.index))
                if scenario == "renewal_reply_lost" and service.index == 1:
                    state.elapsed += helper.ASSERTION_ACQUIRE_TIMEOUT_SECONDS
                    raise asyncio.TimeoutError("fixture command accepted but reply lost")

            async def __aexit__(self, *_):
                state.events.append(("assertion_context_exit", self.service.index))

        class Service:
            def __init__(self, provider):
                if provider is not rsd:
                    raise AssertionError("renewal changed the verified tunnel provider")
                self.index = len(state.services)
                self.commands = 0
                self.close_attempts = 0
                self.closed = False
                state.services.append(self)
                state.events.append(("service_create", self.index))

            async def connect(self):
                state.events.append(("connect", self.index))
                if self.index == 1:
                    if scenario == "renewal_connect_failure":
                        raise ConnectionError("fixture connection failure")
                    if scenario == "owner_lost_during_connect":
                        state.owner = 456
                    if scenario == "stop_during_connect":
                        state.stop = True

            def create_power_assertion(self, assertion_type, name, timeout, details):
                if (assertion_type, name, timeout) != (
                    helper.ASSERTION_TYPE, helper.ASSERTION_NAME, 45
                ) or not details:
                    raise AssertionError("lease contract changed")
                return Assertion(self)

            async def close(self):
                self.close_attempts += 1
                state.events.append(("service_close", self.index))
                if scenario == "service_close_failure" and self.index == 0:
                    raise RuntimeError("fixture service close failure")
                self.closed = True

        async def bounded_wait(awaitable, timeout):
            state.timeouts.append(timeout)
            if timeout == helper.HEARTBEAT_INTERVAL_SECONDS:
                awaitable.close()
                state.elapsed += timeout
                raise asyncio.TimeoutError
            return await awaitable

        def capture_status(_path, **status):
            state.statuses.append(status)
            if status["phase"] == "active" and status["sequence"] >= 65:
                state.stop = True

        args = SimpleNamespace(
            udid=helper.EXACT_HARDWARE_UDID,
            owner_pid=123,
            heartbeat=None,
            stop_file=SimpleNamespace(exists=lambda: state.stop),
        )

        async def run():
            with (
                patch.object(helper, "_load_verified_runtime", return_value=(Tunnel, Service)),
                patch.object(helper, "time", SimpleNamespace(
                    time=lambda: 1000.0 + state.elapsed, monotonic=lambda: state.elapsed
                )),
                patch.object(helper.os, "getppid", side_effect=lambda: state.owner),
                patch.object(helper, "_write_status", side_effect=capture_status),
                patch.object(helper.asyncio, "wait_for", side_effect=bounded_wait),
            ):
                return await helper._run(args)

        state.result = asyncio.run(run())
        state.final = state.statuses[-1]
        return state

    def assert_closed_before_tunnel(self, state):
        tunnel_close = next(i for i, event in enumerate(state.events) if event[0] == "tunnel_close")
        for index, event in enumerate(state.events):
            if event[0] == "service_close":
                self.assertLess(index, tunnel_close)

    def test_three_leases_use_distinct_services_without_dropping_previous_lease(self):
        state = self.run_helper()
        self.assertEqual(state.result, 0)
        self.assertEqual(state.final["phase"], "stopped")
        self.assertEqual(len(state.services), 3)
        self.assertEqual(sum(event[0] == "tunnel_open" for event in state.events), 1)
        for service in state.services:
            self.assertEqual(service.commands, 1)
            self.assertEqual(service.close_attempts, 1)
            self.assertTrue(service.closed)
        for index in (1, 2):
            self.assertLess(
                state.events.index(("acquire", index)),
                state.events.index(("service_close", index - 1)),
            )
        self.assertEqual(state.final["sequence"], 65)
        self.assertTrue(state.final["service_closed"])
        self.assertTrue(state.final["tunnel_closed"])
        self.assertTrue(all(
            not status["service_closed"] and not status["tunnel_closed"]
            for status in state.statuses if status["phase"] == "active"
        ))
        self.assertEqual(set(state.timeouts), {0.5, 5, 8, 15, 30})
        self.assert_closed_before_tunnel(state)

    def test_lost_renewal_reply_preserves_possible_lease_expiry_and_closes_both_services(self):
        state = self.run_helper("renewal_reply_lost")
        self.assertEqual(state.result, 1)
        self.assertEqual(state.final["phase"], "failed")
        self.assertEqual(state.final["error_type"], "TimeoutError")
        self.assertEqual(state.final["sequence"], 30)
        self.assertEqual(state.final["residual_lease_expires_at"], 1065)
        self.assertLessEqual(state.final["residual_lease_expires_at"], int(1000 + state.elapsed) + 45)
        self.assertTrue(all(service.closed for service in state.services))
        self.assertTrue(state.final["service_closed"])
        self.assertTrue(state.final["tunnel_closed"])
        self.assert_closed_before_tunnel(state)

    def test_connect_failure_keeps_last_known_lease_and_closes_inflight_service(self):
        state = self.run_helper("renewal_connect_failure")
        self.assertEqual(state.result, 1)
        self.assertEqual(state.final["phase"], "failed")
        self.assertEqual(state.final["residual_lease_expires_at"], 1045)
        self.assertEqual([service.commands for service in state.services], [1, 0])
        self.assertTrue(all(service.closed for service in state.services))
        self.assert_closed_before_tunnel(state)

    def test_stop_or_owner_loss_during_connect_prevents_the_next_command(self):
        for scenario in ("stop_during_connect", "owner_lost_during_connect"):
            with self.subTest(scenario=scenario):
                state = self.run_helper(scenario)
                self.assertEqual(state.result, 0)
                self.assertEqual(state.final["phase"], "stopped")
                self.assertEqual([service.commands for service in state.services], [1, 0])
                self.assertTrue(all(service.closed for service in state.services))
                self.assert_closed_before_tunnel(state)

    def test_wrong_device_never_creates_a_power_service(self):
        state = self.run_helper("wrong_device")
        self.assertEqual(state.result, 1)
        self.assertEqual(state.services, [])
        self.assertIsNone(state.final["residual_lease_expires_at"])
        self.assertTrue(state.final["tunnel_closed"])

    def test_cleanup_failures_are_not_reported_as_clean_teardown(self):
        for scenario, closed_key in (
            ("service_close_failure", "service_closed"),
            ("tunnel_close_failure", "tunnel_closed"),
        ):
            with self.subTest(scenario=scenario):
                state = self.run_helper(scenario)
                self.assertEqual(state.result, 1)
                self.assertEqual(state.final["phase"], "failed")
                self.assertEqual(state.final["error_type"], "RuntimeError")
                self.assertFalse(state.final[closed_key])
                self.assertLessEqual(state.final["residual_lease_expires_at"], int(1000 + state.elapsed) + 45)
                self.assert_closed_before_tunnel(state)


if __name__ == "__main__":
    unittest.main()
