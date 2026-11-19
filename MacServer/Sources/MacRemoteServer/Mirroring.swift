import Foundation

/// AirPlay screen mirroring, driven through the Screen Mirroring menu in Control Center.
///
/// macOS has no API for starting AirPlay mirroring, so this uses AppleScript GUI scripting
/// (System Events), exactly as if you clicked the menu yourself. It needs Accessibility permission
/// (already required) and, the first time, macOS asks to allow controlling "System Events".
/// It relies on Control Center's layout, which Apple sometimes changes between macOS versions;
/// errors are passed back to the phone.
enum Mirroring {
    struct Screen {
        let name: String
        let connected: Bool
    }

    enum Action: String {
        case list, connect, stop, open
    }

    private static var busy = false
    private static var queued: [(Action, String?, (Result<[Screen], MirroringError>) -> Void)] = []

    struct MirroringError: Error {
        let message: String
    }

    /// Runs one action at a time (scripts drive the same menu, so they must not overlap).
    static func perform(_ action: Action, name: String? = nil,
                        completion: @escaping (Result<[Screen], MirroringError>) -> Void) {
        queued.append((action, name, completion))
        runNext()
    }

    private static func runNext() {
        guard !busy, !queued.isEmpty else { return }
        let (action, name, completion) = queued.removeFirst()
        busy = true
        SystemActions.run("/usr/bin/osascript", ["-e", script, action.rawValue, name ?? ""]) { result in
            busy = false
            if result.status == 0 {
                completion(.success(parse(result.output)))
            } else {
                print("🖥  Screen Mirroring script error: \(result.error)")
                completion(.failure(MirroringError(message: friendly(result.error))))
            }
            runNext()
        }
    }

    /// Output lines are "name<TAB>1" (mirroring to it) or "name<TAB>0".
    private static func parse(_ output: String) -> [Screen] {
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = parts.first else { return nil }
            let name = String(first).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return Screen(name: name, connected: parts.count > 1 && parts[1] == "1")
        }
    }

    private static func friendly(_ error: String) -> String {
        if error.contains("-1743") || error.localizedCaseInsensitiveContains("not allowed to send") {
            return "Your Mac blocked controlling System Events. Allow it in System Settings → Privacy & Security → Automation (turn on System Events for Terminal or MacRemoteServer), then try again."
        }
        // -1719 also means "invalid index" (an item wasn't found), so only blame permissions when the
        // message actually says so.
        if error.contains("-25211") || error.localizedCaseInsensitiveContains("assistive access") {
            return "Accessibility permission is missing for Terminal or MacRemoteServer (System Settings → Privacy & Security → Accessibility)."
        }
        // osascript errors look like "123:456: execution error: <message> (-2700)"
        if let range = error.range(of: "execution error: ") {
            return String(error[range.upperBound...])
        }
        return error.isEmpty ? "Screen Mirroring didn't respond." : error
    }

    // MARK: - AppleScript

    private static let script = #"""
    on run argv
        set requestedAction to item 1 of argv
        set targetName to ""
        if (count of argv) > 1 then set targetName to item 2 of argv

        my openPanel()
        if requestedAction is "open" then return ""

        set screenList to my waitForScreens()

        if requestedAction is "connect" then
            my clickScreen(targetName, false)
            delay 2
            set screenList to my readScreens()
        else if requestedAction is "stop" then
            my clickScreen("", true)
            delay 1
            set screenList to my readScreens()
        end if

        my closePanel()
        return my formatScreens(screenList)
    end run

    -- Returns the menu bar item of Control Center whose identifier or description matches.
    on menuBarItemMatching(identifierPart, descriptionPart)
        tell application "System Events" to tell process "ControlCenter"
            repeat with mbi in menu bar items of menu bar 1
                set ident to ""
                try
                    set ident to (value of attribute "AXIdentifier" of mbi) as text
                end try
                set desc to ""
                try
                    set desc to (description of mbi) as text
                end try
                if ident contains identifierPart or desc contains descriptionPart then return mbi
            end repeat
        end tell
        return missing value
    end menuBarItemMatching

    on openPanel()
        -- 1) The Screen Mirroring icon in the menu bar, if it's shown there.
        set mirroringItem to my menuBarItemMatching("screenmirroring", "Screen Mirroring")
        if mirroringItem is not missing value then
            tell application "System Events" to click mirroringItem
            delay 0.8
            return
        end if

        -- 2) Otherwise open Control Center and press its Screen Mirroring tile.
        set ccItem to my menuBarItemMatching("controlcenter", "Control Center")
        if ccItem is missing value then error "Couldn't find Control Center in the menu bar."
        tell application "System Events"
            click ccItem
            delay 0.8
            tell process "ControlCenter"
                set tile to missing value
                repeat with el in (entire contents of window 1)
                    try
                        set r to role of el
                        if r is "AXCheckBox" or r is "AXButton" then
                            set itemLabel to ""
                            try
                                set itemLabel to (description of el) as text
                            end try
                            if itemLabel does not contain "Mirroring" then
                                try
                                    set itemLabel to (name of el) as text
                                end try
                            end if
                            if itemLabel contains "Mirroring" then
                                set tile to el
                                exit repeat
                            end if
                        end if
                    end try
                end repeat
                if tile is missing value then
                    key code 53
                    error "Couldn't find Screen Mirroring in Control Center."
                end if
                click tile
            end tell
        end tell
        delay 0.8
    end openPanel

    on closePanel()
        tell application "System Events" to key code 53 -- Escape
    end closePanel

    -- Each screen in the panel is a checkbox: {name, isChecked}.
    on readScreens()
        set found to {}
        tell application "System Events" to tell process "ControlCenter"
            try
                repeat with el in (entire contents of window 1)
                    try
                        if (role of el) is "AXCheckBox" then
                            set itemLabel to ""
                            try
                                set itemLabel to (name of el) as text
                            end try
                            if itemLabel is "" or itemLabel is "missing value" then
                                try
                                    set itemLabel to (description of el) as text
                                end try
                            end if
                            set isChecked to 0
                            try
                                set isChecked to (value of el) as integer
                            end try
                            if itemLabel is not "" and itemLabel is not "missing value" and itemLabel does not contain "Mirroring" then
                                set end of found to {itemLabel, isChecked}
                            end if
                        end if
                    end try
                end repeat
            end try
        end tell
        return found
    end readScreens

    -- AirPlay devices take a moment to show up after the panel opens.
    on waitForScreens()
        repeat 10 times
            set screenList to my readScreens()
            if (count of screenList) > 0 then return screenList
            delay 0.4
        end repeat
        return {}
    end waitForScreens

    on clickScreen(targetName, onlyChecked)
        tell application "System Events" to tell process "ControlCenter"
            repeat with el in (entire contents of window 1)
                try
                    if (role of el) is "AXCheckBox" then
                        set itemLabel to ""
                        try
                            set itemLabel to (name of el) as text
                        end try
                        if itemLabel is "" or itemLabel is "missing value" then
                            try
                                set itemLabel to (description of el) as text
                            end try
                        end if
                        set isChecked to 0
                        try
                            set isChecked to (value of el) as integer
                        end try
                        if (onlyChecked and isChecked is 1 and itemLabel does not contain "Mirroring") or ((not onlyChecked) and itemLabel is targetName) then
                            click el
                            return
                        end if
                    end if
                end try
            end repeat
        end tell
        my closePanel()
        if onlyChecked then
            error "Your Mac isn't mirroring to anything right now."
        else
            error "Couldn't find “" & targetName & "” in Screen Mirroring. Make sure the TV is on and on the same Wi-Fi."
        end if
    end clickScreen

    on formatScreens(screenList)
        set out to ""
        repeat with s in screenList
            set out to out & (item 1 of s) & tab & (item 2 of s) & linefeed
        end repeat
        return out
    end formatScreens
    """#
}
