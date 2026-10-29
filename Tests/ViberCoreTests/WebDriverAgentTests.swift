import CoreGraphics
import XCTest
@testable import ViberCore

final class WebDriverAgentTests: XCTestCase {
    static let xcodePrefs = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>IDEProvisioningTeamByIdentifier</key><dict>
            <key>E282</key><array>
              <dict><key>isFreeProvisioningTeam</key><true/><key>teamID</key><string>2FZ4LY3MZ3</string>
                    <key>teamName</key><string>Jeremy Trips (Personal Team)</string></dict>
              <dict><key>isFreeProvisioningTeam</key><false/><key>teamID</key><string>4CA6NAHTNM</string>
                    <key>teamName</key><string>PinSound</string></dict>
            </array>
          </dict>
        </dict></plist>
        """

    func testPicksThePaidTeamUnlessOneIsSet() throws {
        let teams = WebDriverAgent.parseTeams(Data(Self.xcodePrefs.utf8))
        XCTAssertEqual(teams.map(\.id), ["4CA6NAHTNM", "2FZ4LY3MZ3"], "paid teams first")
        XCTAssertEqual(try WebDriverAgent.chooseTeam(teams, preferred: nil).name, "PinSound")
        XCTAssertEqual(try WebDriverAgent.chooseTeam(teams, preferred: "2FZ4LY3MZ3").free, true)
        let personal = teams.filter(\.free)
        XCTAssertEqual(try WebDriverAgent.chooseTeam(personal, preferred: nil).id, "2FZ4LY3MZ3")
        XCTAssertThrowsError(try WebDriverAgent.chooseTeam([], preferred: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("Xcode → Settings → Accounts"))
        }
        let two = teams + [WebDriverAgent.Team(id: "ABCDE12345", name: "Other", free: false)]
        XCTAssertThrowsError(try WebDriverAgent.chooseTeam(two, preferred: nil)) {
            XCTAssertTrue($0.localizedDescription.contains(WebDriverAgent.teamDefaultsKey))
        }
        XCTAssertEqual(WebDriverAgent.bundleID(team: "4CA6NAHTNM"), "dev.viber.wda.4ca6nahtnm.WebDriverAgentRunner")
    }

    func testFindsTheServerURLAndTheTunnel() throws {
        XCTAssertEqual(WebDriverAgent.serverURL(in: "    t =     0.10s ServerURLHere->http://192.168.1.20:8100<-ServerURLHere")?.absoluteString,
                       "http://192.168.1.20:8100")
        XCTAssertNil(WebDriverAgent.serverURL(in: "Testing started"))
        XCTAssertEqual(WebDriverAgent.tunnelURL("fd71:73b:203f::1")?.absoluteString, "http://[fd71:73b:203f::1]:8100")
        XCTAssertEqual(WebDriverAgent.tunnelURL("fd71:73b:203f::1")?.host, "fd71:73b:203f::1")
        let details = """
            {"result": {"connectionProperties": {"tunnelIPAddress": "fd71:73b:203f::1", "tunnelState": "connected", "transportType": "localNetwork"}}}
            """
        XCTAssertEqual(Devicectl.parseTunnelAddress(Data(details.utf8)), "fd71:73b:203f::1")
        let down = details.replacingOccurrences(of: "\"connected\"", with: "\"disconnected\"")
        XCTAssertNil(Devicectl.parseTunnelAddress(Data(down.utf8)))
    }

    func testReadsTheSourceTree() throws {
        let source = """
            {"type": "Application", "label": "Settings", "name": "Settings", "rawIdentifier": null, "value": null, "isEnabled": "1",
             "rect": {"x": 0, "y": 0, "width": 402, "height": 874},
             "children": [
              {"type": "Button", "label": "General", "name": "General", "rawIdentifier": "com.apple.settings.general", "value": "",
               "isEnabled": "1", "rect": {"x": 16, "y": 300, "width": 370, "height": 52}},
              {"type": "TextField", "label": "", "name": "Search", "rawIdentifier": null, "value": "Search",
               "isEnabled": "0", "rect": {"x": 16, "y": 120, "width": 370, "height": 36}}
             ]}
            """
        let root = try XCTUnwrap(WebDriverAgentClient.element(try XCTUnwrap(JSON(data: Data(source.utf8)))))
        let tree = UITree(root: root)
        XCTAssertEqual(tree.app, "Settings")
        let general = try XCTUnwrap(tree.find("General"))
        XCTAssertEqual(general.role, "Button")
        XCTAssertEqual(general.identifier, "com.apple.settings.general")
        XCTAssertNil(general.value, "empty strings are no value")
        XCTAssertEqual(general.center, CGPoint(x: 201, y: 326))
        let search = try XCTUnwrap(tree.find("Search"))
        XCTAssertNil(search.label)
        XCTAssertFalse(search.enabled)
    }

    func testGesturesAreW3CPointerActions() throws {
        let tap = WebDriverAgentClient.actions([CGPoint(x: 10.4, y: 20.6)], duration: 0.06)
        let steps = try XCTUnwrap(tap["actions"]?[0]?["actions"]?.array)
        XCTAssertEqual(steps.map { $0["type"]?.string }, ["pointerMove", "pointerDown", "pause", "pointerUp"])
        XCTAssertEqual(steps[0]["x"]?.double, 10)
        XCTAssertEqual(steps[0]["y"]?.double, 21)
        XCTAssertEqual(steps[2]["duration"]?.int, 60)
        XCTAssertEqual(tap["actions"]?[0]?["parameters"]?["pointerType"]?.string, "touch")

        let path = (0...60).map { CGPoint(x: 200, y: 700 - Double($0) * 10) }
        let swipe = try XCTUnwrap(WebDriverAgentClient.actions(path, duration: 0.3)["actions"]?[0]?["actions"]?.array)
        let moves = swipe.dropFirst(2).dropLast()
        XCTAssertLessThanOrEqual(moves.count, 10)
        XCTAssertEqual(moves.last?["y"]?.double, 100, "ends where the path ends")
        XCTAssertEqual(swipe.last?["type"]?.string, "pointerUp")
    }

    func testBuildErrorsAreTheErrorLines() {
        let log = """
            Build settings from command line:
            /tmp/WebDriverAgent.xcodeproj: error: No Account for Team "ABC". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'WebDriverAgentRunner' from project 'WebDriverAgent')
            /tmp/WebDriverAgent.xcodeproj: error: No Account for Team "ABC". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'WebDriverAgentRunner' from project 'WebDriverAgent')
            ** BUILD FAILED **
            """
        XCTAssertEqual(WebDriverAgent.buildError(log),
                       "No Account for Team \"ABC\". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'WebDriverAgentRunner' from project 'WebDriverAgent')")
    }
}
