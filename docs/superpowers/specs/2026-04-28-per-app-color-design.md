---
date: 2026-04-28
topic: Per-App Color Override
status: design
---

# Per-App Color Override

Allow the user to assign a custom color to any app in the sidebar via a right-click context menu. The override is per-repo, per-app, persisted in SwiftData, and synced through the existing CloudKit-backed container.

## Motivation

Today each app's sidebar swatch is auto-assigned from `ColorPalette` based on the sorted index of the app within its repo. The user wants control: pick a color from the same 12-color palette via right-click → Color → swatch.

## Data Model

Add a stored property to `Repo` (`AppFeedback/Models/Repo.swift`):

```swift
var appColors: [String: String] = [:]   // appName → hex string (no leading "#")
```

- Lives on the existing `@Model` `Repo`, so it syncs through the same CloudKit-backed container as `hiddenAppNames`.
- Default `[:]` is required for CloudKit compatibility (matches the existing pattern).
- Hex string format matches what `Color(hex:)` already parses.

Constructor: extend `init(...)` with `appColors: [String: String] = [:]`.

## Store

Extend `RepoStore` (`AppFeedback/Services/RepoStore.swift`):

- New observed cache: `private(set) var appColors: [UUID: [String: String]] = [:]`
- Populate in `reload()` alongside `hiddenApps`:
  ```swift
  let newAppColors = Dictionary(
      uniqueKeysWithValues: models.map { ($0.id, $0.appColors) }
  )
  if appColors != newAppColors { appColors = newAppColors }
  ```
- New mutation:
  ```swift
  func setColor(_ hex: String, forApp appName: String, in repoId: UUID) {
      guard let model = fetchModel(id: repoId) else { return }
      if model.appColors[appName] == hex { return }
      model.appColors[appName] = hex
      save()
      reload()
  }
  ```
- New accessor:
  ```swift
  func colorHexFor(app appName: String, in repoId: UUID) -> String? {
      appColors[repoId]?[appName]
  }
  ```

## Color Resolution

In `RepoSectionView`, replace the existing `ColorPalette.color(for:in:)` call with:

```swift
let color: Color = {
    if let hex = store.colorHexFor(app: app, in: repo.id) {
        return Color(hex: hex)
    }
    return ColorPalette.color(for: app, in: allApps)
}()
```

`AppRowView` and `ColorPalette` are unchanged.

## UI

Add a `.contextMenu { … }` modifier to the per-app `AppRowView` inside `RepoSectionView`:

```swift
.contextMenu {
    Menu {
        ForEach(ColorPalette.palette.indices, id: \.self) { i in
            let hex = ColorPalette.paletteHex[i]
            Button {
                store.setColor(hex, forApp: app, in: repo.id)
            } label: {
                Label(hex.uppercased(), systemImage: "circle.fill")
            }
        }
    } label: {
        Label("Color", systemImage: "paintpalette")
    }
}
```

To make the swatches accessible from the menu, expose the hex strings explicitly:

```swift
// ColorPalette.swift
static let paletteHex: [String] = [
    "4ef8d0", "7b8cff", "ff6b8a", "ffb347",
    "a78bfa", "34d399", "f87171", "60a5fa",
    "fbbf24", "e879f9", "38bdf8", "fb923c",
]
static let palette: [Color] = paletteHex.map(Color.init(hex:))
```

This guarantees `palette` and `paletteHex` stay aligned.

Per the user's decision, there is **no "Default / Reset" item** — once a color is set it persists until replaced by another pick.

## Sync

No additional CloudKit work. `appColors` is a stored property on an existing synced `@Model`, so changes propagate via the same mechanism that already moves `hiddenAppNames` between devices. `RepoStore`'s existing `NSPersistentStoreRemoteChange` observer will trigger `reload()` and refresh the UI when an override arrives from another device.

## Tests

Extend `AppFeedbackTests/RepoStoreTests.swift`:

- `setColor` writes to the model and updates the published cache.
- Calling `setColor` with the same hex twice is a no-op (no duplicate save churn).
- `colorHexFor` returns nil for unset apps and the stored hex for set apps.
- After remove + re-fetch, the override survives a reload (round-trip through SwiftData).

## Out of Scope

- Custom color picker / arbitrary hex entry (only the fixed 12-color palette is offered).
- Resetting back to auto-assigned color.
- Bulk color editing UI.
