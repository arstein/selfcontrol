import SwiftUI
// TEMPORARY - each placeholder is deleted by the task that implements the real view.
struct BlockingView: View { var body: some View { Text("Blocking") } }
struct EmergencyUnlockView: View { var body: some View { Text("Emergency") } }
struct OverrideConfirmSheet: View { var body: some View { Text("Confirm") } }
struct ExtendSheet: View { let initialMinutes: Int; var body: some View { Text("Extend") } }
