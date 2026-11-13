import Testing

@testable import Untunnel

@Suite("UserFacingError")
struct UserFacingErrorTests {
    @Test
    func rendersEveryCaseWithACommandOrMenuItemInTheFix() {
        for error in UserFacingError.allCases {
            #expect(error.rendered == "\(error.message)\nFix: \(error.fix)")

            let namesACommand =
                error.fix.contains("`untunnel ") || error.fix.contains("`~/Applications")
            let namesAMenuItem =
                error.fix.contains("menu")
                || error.fix.contains("System Settings")
                || error.fix.contains("Finder")
            #expect(namesACommand || namesAMenuItem)
        }
    }

    @Test
    func namesTheScriptInstallAndItsUninstallCommand() {
        let error = UserFacingError.installedByScript

        #expect(error.message == "Untunnel is already installed by the install script.")
        #expect(
            error.fix
                == "Run `~/Applications/Untunnel.app/Contents/MacOS/Untunnel uninstall`, then run `untunnel setup`."
        )
    }
}
