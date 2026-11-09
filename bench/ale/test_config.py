"""FaConfig tests (issue #1686).

The config is the deployer's only consumer contract: defaults must stay
byte-identical to the bench provider identity (REG-1 parity with
bench.yml / bench-harbor.yml gh-1471), and the knob fields must default
to the no-clock contract (fa never invents a clock).
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import config  # noqa: E402


class FaConfigDefaultsTest(unittest.TestCase):
    def test_default_provider_config_is_reg1_byte_identical(self):
        cfg = config.FaConfig()
        parsed = json.loads(cfg.provider_config)
        self.assertEqual(
            parsed,
            {
                "baseUrl": "https://api.z.ai/api/coding/paas/v4",
                "model": "glm-5.3-flash",
                "apiKeyEnvVar": "FA_KEY_API_Z_AI_Z_AI",
            },
        )
        self.assertEqual(cfg.provider_type, "zai")
        self.assertEqual(cfg.model, "glm-5.3-flash")

    def test_no_clock_contract_by_default(self):
        cfg = config.FaConfig()
        # Every timeout knob absent: the deployer must not export a
        # deadline or run the watch from bare defaults.
        self.assertFalse(cfg.progress_extension)
        self.assertIsNone(cfg.stall_gap_sec)
        self.assertIsNone(cfg.abs_ceiling_sec)
        self.assertIsNone(cfg.external_cap_sec)
        self.assertIsNone(cfg.api_key)
        self.assertIsNone(cfg.bundle_sha256)

    def test_key_never_rides_provider_config(self):
        # The provider_config JSON names the KEY ENV VAR, never the key;
        # the key travels only via api_key (the ${env:} preset field).
        cfg = config.FaConfig(api_key="super-secret-value")
        self.assertNotIn("super-secret-value", cfg.provider_config)
        self.assertEqual(
            json.loads(cfg.provider_config)["apiKeyEnvVar"],
            "FA_KEY_API_Z_AI_Z_AI",
        )
        self.assertEqual(cfg.api_key, "super-secret-value")

    def test_config_name_is_the_framework_identity(self):
        # ale_run factory reads config.name as the agent identity
        # (lifecycle: agent_name = getattr(config, "name", ...)).
        self.assertEqual(config.FaConfig.name, "fa")


if __name__ == "__main__":
    unittest.main()
