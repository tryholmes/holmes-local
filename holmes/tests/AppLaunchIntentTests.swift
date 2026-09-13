import Foundation

@main struct AppLaunchIntentTests {
    static func main() {
        let launches: [(String, String)] = [
            ("open Spotify", "Spotify"),
            ("Open Spotify.", "Spotify"),
            ("open spotify?", "spotify"),
            ("Can you open Spotify?", "Spotify"),
            ("could you please open Spotify for me?", "Spotify"),
            ("would you launch Spotify please", "Spotify"),
            ("please open up the Spotify app", "Spotify"),
            ("hey Holmes, open Spotify", "Spotify"),
            ("hey open Spotify", "Spotify"),
            ("hey, can you open Spotify?", "Spotify"),
            ("agent, open Spotify", "Spotify"),
            ("switch to Spotify", "Spotify"),
            ("bring up Spotify", "Spotify"),
            ("start Spotify now", "Spotify"),
            ("open Spotify.app", "Spotify.app"),
            ("open com.spotify.client", "com.spotify.client"),
            ("open Google Chrome", "Google Chrome"),
            ("open Apple Notes", "Notes"),
            ("open \"Spotify\"", "Spotify"),
            ("open Microsoft To Do", "Microsoft To Do"),
            ("  open\n Spotify  ", "Spotify"),
            ("open MissingApp", "MissingApp")
        ]
        for (query, expected) in launches {
            let actual = AppLaunchIntent.appName(in: query)
            precondition(actual == expected, "\(query): expected \(expected), got \(actual ?? "nil")")
        }
        let otherRequests = [
            "How do I open Spotify?", "Can you explain how to open Spotify?",
            "Why won't Spotify open?", "Is Spotify open?", "don't open Spotify",
            "do not open Spotify", "open Spotify and play music", "open Spotify then play music",
            "open Spotify, play music", "open Spotify; play music", "open the file",
            "open a new tab", "open my downloads", "start recording", "open https://spotify.com",
            "/ask open Spotify", "open /Applications/Spotify.app", "open it", "open", ""
        ]
        for query in otherRequests {
            precondition(AppLaunchIntent.appName(in: query) == nil, "Must not launch directly: \(query)")
        }
        print("App launch intent: \(launches.count + otherRequests.count) checks passed")
    }
}
