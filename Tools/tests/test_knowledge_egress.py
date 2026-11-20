import unittest

from Tools.check_static_policy import RULES_BY_NAME


class KnowledgeEgressTests(unittest.TestCase):
    def test_knowledge_code_cannot_reach_the_network_directly(self):
        rule = RULES_BY_NAME["knowledge-network"]
        for path in ("Kurn/Application/Knowledge/KnowledgeStore.swift",
                     "Kurn/Application/Agent/Tools/ChatKnowledgeTools.swift",
                     "Kurn/Views/KnowledgeGraphView.swift",
                     "Kurn/Views/MeetingKnowledgeView.swift",
                     "Packages/KurnCore/Sources/KurnCore/Knowledge/KnowledgePolicy.swift"):
            with self.subTest(path=path):
                self.assertTrue(rule.applies_to(path))
        for source in ("let session = URLSession.shared", "var request = URLRequest(url: url)",
                       "try await LLMHTTP.sendValidated(request)", "CKContainer.default()",
                       "NSUbiquitousKeyValueStore.default.set(1, forKey: k)"):
            with self.subTest(source=source):
                self.assertIsNotNone(rule.pattern.search(source))
        self.assertIsNone(rule.pattern.search("let provider = ProviderFactory.make(selection)"))
        self.assertFalse(rule.applies_to("Kurn/Providers/ProviderHTTPTransport.swift"))
