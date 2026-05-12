#if os(iOS)
import SwiftUI

struct IOSEmailSettingsView: View {
    var body: some View {
        NavigationStack {
            IOSEmailAccountList()
        }
    }
}
#endif
