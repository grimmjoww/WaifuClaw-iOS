import Security
import XCTest
@testable import WaifuClaw

final class JevDecisionTests: XCTestCase {
    func testDecodesKnownTypedResponse() throws {
        let data = Data(
            """
            {
              "model": "jev-1.13.0",
              "answers": {
                "intent": {
                  "type": "choice",
                  "choice": "inspect",
                  "probabilities": { "inspect": 0.72, "general": 0.28 },
                  "confidence": 0.61
                },
                "needs_write": { "type": "noul", "noul": 0.83 }
              },
              "usage": { "input_tokens": 127, "output_tokens": 21 }
            }
            """.utf8
        )

        let assessment = try JevDecisionClient.decodeAssessment(from: data)

        XCTAssertEqual(assessment.model, "jev-1.13.0")
        XCTAssertEqual(assessment.intent.choice, .inspect)
        XCTAssertEqual(assessment.intent.probabilities.inspect, 0.72, accuracy: 0.000_001)
        XCTAssertEqual(assessment.intent.probabilities.general, 0.28, accuracy: 0.000_001)
        XCTAssertEqual(assessment.intent.confidence, 0.61, accuracy: 0.000_001)
        XCTAssertEqual(assessment.needsWrite.probability, 0.83, accuracy: 0.000_001)
        XCTAssertEqual(assessment.usage, JevUsage(inputTokens: 127, outputTokens: 21))
    }

    func testRejectsChoiceOutsideTheFixedCriteria() {
        let data = Data(
            """
            {
              "model": "jev-1.13.0",
              "answers": {
                "intent": {
                  "type": "choice",
                  "choice": "write",
                  "probabilities": { "inspect": 0.5, "general": 0.5 },
                  "confidence": 0.1
                },
                "needs_write": { "type": "noul", "noul": 0.5 }
              },
              "usage": { "input_tokens": 1, "output_tokens": 1 }
            }
            """.utf8
        )

        XCTAssertThrowsError(try JevDecisionClient.decodeAssessment(from: data)) { error in
            XCTAssertEqual(error as? JevDecisionError, .invalidResponse)
        }
    }

    func testRejectsInvalidProbabilityDistributionAndWrongAnswerType() {
        let data = Data(
            """
            {
              "model": "jev-1.13.0",
              "answers": {
                "intent": {
                  "type": "noul",
                  "choice": "inspect",
                  "probabilities": { "inspect": 0.7, "general": 0.7 },
                  "confidence": 1.2
                },
                "needs_write": { "type": "choice", "noul": -0.1 }
              },
              "usage": { "input_tokens": -1, "output_tokens": 1 }
            }
            """.utf8
        )

        XCTAssertThrowsError(try JevDecisionClient.decodeAssessment(from: data)) { error in
            XCTAssertEqual(error as? JevDecisionError, .invalidResponse)
        }
    }

    func testRequestUsesFixedEndpointAndMinimalState() throws {
        let request = try JevDecisionClient.makeURLRequest(
            request: "Please inspect the selected project for TODOs.",
            workspaceSelected: true,
            apiKey: "not-a-real-key"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer not-a-real-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "jev-latest")
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(Set(state.keys), Set(["request", "workspace_selected"]))
        XCTAssertEqual(state["request"] as? String, "Please inspect the selected project for TODOs.")
        XCTAssertEqual(state["workspace_selected"] as? Bool, true)
        XCTAssertNil(state["project_contents"])
        XCTAssertNil(state["workspace_path"])

        let questions = try XCTUnwrap(object["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), Set(["intent", "needs_write"]))
    }

    func testDecisionOptInDefaultsOffAndPersistsExplicitChoice() {
        let suite = "JevDecisionTests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = JevDecisionPreferences(defaults: defaults)
        XCTAssertFalse(preferences.isDecisionOptedIn)
        preferences.isDecisionOptedIn = true
        XCTAssertTrue(JevDecisionPreferences(defaults: defaults).isDecisionOptedIn)
    }

    func testDedicatedKeychainRejectsBlankKeyBeforeStorageAccess() {
        let storage = JevKeychainStore(
            service: "studio.phantomhorizons.waifuclaw.tests.jev.\(UUID().uuidString)",
            account: "blankKeyValidation"
        )

        XCTAssertThrowsError(try storage.save(" \n\t ")) { error in
            XCTAssertEqual(error as? JevKeychainStore.StorageError, .invalidKey)
        }
    }

    func testDedicatedKeychainRoundTripWhenAvailable() throws {
        let storage = JevKeychainStore(
            service: "studio.phantomhorizons.waifuclaw.tests.jev.\(UUID().uuidString)",
            account: "isolatedTestKey"
        )
        defer { try? storage.delete() }

        do {
            XCTAssertNil(try storage.load())
            try storage.save("not-a-real-jev-key")
            XCTAssertEqual(try storage.load(), "not-a-real-jev-key")
            try storage.delete()
            XCTAssertNil(try storage.load())
        } catch let error as JevKeychainStore.StorageError {
            if case let .status(status) = error,
               [errSecNotAvailable, errSecInteractionNotAllowed].contains(status) {
                throw XCTSkip("The current test host does not expose an unlocked Keychain: \(status)")
            }
            throw error
        }
    }
}
