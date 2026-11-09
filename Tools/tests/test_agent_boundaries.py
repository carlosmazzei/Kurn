import unittest

from Tools.check_static_policy import RULES_BY_NAME


class AgentBoundaryTests(unittest.TestCase):
    def test_domain_cannot_import_runtime_in_any_import_form(self):
        rule = RULES_BY_NAME["domain-agent-dependency"]
        self.assertTrue(rule.applies_to("Packages/KurnCore/Sources/KurnCore/Chat/Source.swift"))
        for source in ("import AgentHarness", "@_exported import AgentHarness",
                       "import struct AgentHarness.AgentRunStep"):
            with self.subTest(source=source):
                self.assertIsNotNone(rule.pattern.search(source))
        self.assertFalse(rule.applies_to("Kurn/Application/Agent/Tools/Source.swift"))
        self.assertIsNone(rule.pattern.search("import Foundation"))

    def test_runtime_cannot_depend_on_domain_or_apple_adapters(self):
        rule = RULES_BY_NAME["agent-domain-dependency"]
        self.assertTrue(rule.applies_to("Packages/AgentHarness/Sources/AgentHarness/Runtime.swift"))
        for module in ("KurnCore", "Kurn", "SwiftData", "SwiftUI"):
            with self.subTest(module=module):
                self.assertIsNotNone(rule.pattern.search(f"import {module}"))
        self.assertFalse(rule.applies_to("Kurn/Providers/Transport.swift"))
        self.assertIsNone(rule.pattern.search("import Foundation"))
