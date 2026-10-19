import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

const root = new URL("../Vellix/", import.meta.url);
const read = file => readFile(new URL(file, root), "utf8");
const sheets = {
  "Accounts/SignInView.swift": ["SignInView"],
  "Accounts/AccountLibrarySheet.swift": ["AccountLibrarySheet"],
  "Accounts/AccountSettingsView.swift": ["AccountDetailSheet", "AccountSwitcherSheet"],
  "Attachments/AttachmentEditorSheet.swift": ["AttachmentEditorSheet"],
  "Calendar/CalendarEventDetailSheet.swift": ["CalendarEventDetailSheet"],
  "Collections/CollectionDocumentIntegration.swift": ["CollectionCreateSheet", "CollectionAddEntrySheet", "CollectionEntryActionsSheet"],
  "Collections/CollectionPropertySheets.swift": ["CollectionValueSheet", "CollectionFieldEditorSheet"],
  "Collections/CollectionViewSheets.swift": ["CollectionManagementSheet", "CollectionAddViewSheet", "CollectionViewEditorSheet", "CollectionFilterSheet"],
  "Collections/CollectionKanbanView.swift": ["CollectionKanbanColumnsSheet", "CollectionKanbanColumnEditor"],
  "DailyNotes/TemplateComponentEditorSheet.swift": ["TemplateComponentEditorSheet"],
  "Documents/FolderLibraryViews.swift": ["FolderEditorSheet", "FolderDestinationPicker"],
  "Editor/CardBackdropSheet.swift": ["CardBackdropSheet"],
  "Editor/CardPhotoSearchSheet.swift": ["CardPhotoSearchSheet"],
  "Editor/CardThreeModeColorPicker.swift": ["CardThreeModeColorPicker"],
  "Editor/DocumentEditorView.swift": ["VellixIconLibraryPicker", "SnapshotHistoryView", "SelectedBlockActionsSheet"],
  "Editor/DocumentStyleSheet.swift": ["DocumentStyleSheet"],
  "Editor/InlinePropertyEditorSheet.swift": ["InlinePropertyEditorSheet", "InlinePropertyOptionEditor"],
  "Editor/PageCardEditorSheet.swift": ["PageCardEditorSheet"],
  "Editor/TableEditorSheet.swift": ["TableEditorSheet"],
  "Editor/TaskEditorSheet.swift": ["TaskEditorSheet"],
  "Spaces/PennedSettingsView.swift": ["SpacePickerSheet"],
  "Spaces/SpaceViews.swift": ["SpaceEditorSheet", "SpaceTransferSheet"],
  "Tags/TagBrowserView.swift": ["MatchingTagBlocksSheet"],
  "Tags/TagEditorIntegration.swift": ["TagActionsSheet", "TagSelectorSheet"],
};

function declaration(source, name) {
  const start = source.indexOf(`struct ${name}:`);
  assert.notEqual(start, -1, `Missing sheet declaration: ${name}`);
  const remainder = source.slice(start);
  const next = /\n(?:private |final |private final )?(?:struct|class|enum|extension)\s/.exec(remainder);
  return next ? remainder.slice(0, next.index) : remainder;
}

test("Sign In uses Penned tokens and shared chrome without changing the Apple authentication flow", async () => {
  const source = await read("Accounts/SignInView.swift");
  assert.doesNotMatch(source, /\b(?:LColors|LSpacing)\b|accentGradient|gradientPurple|VellixBackground\(|\.shadow\(/);
  for (const token of ["VellixSpacing.lg", "VellixRadius.md", "VellixSurface.ink", "VellixSurface.coral", "VellixSurface.violet"]) assert.ok(source.includes(token), token);
  assert.doesNotMatch(source, /Log in to sync your data across devices/);
  assert.match(source, /\.fontDesign\(\.rounded\)\s*\.fontWeight\(\.black\)/);
  assert.match(source, /ScrollView \{/);
  assert.match(source, /\.pennedSheet\(title: emailFlow \? "Continue with Email" : "Sign In", close: \{ cancelEmail\(\); dismiss\(\) \}\)/);
  assert.match(source, /SignInWithAppleButton\(\.continue\)[\s\S]*?request\.requestedScopes = \[\.fullName, \.email\]/);
  assert.match(source, /\.signInWithAppleButtonStyle\(\.black\)/);
  assert.match(source, /\.disabled\(isSigningIn\)/);
  assert.match(source, /appState\.signInWithApple\(\s*credential: credential,\s*existingUsers: authUsers,\s*modelContext: modelContext\s*\)/);
  assert.match(source, /authError\.code == \.canceled/);
});

test("Account Settings uses one existing custom back button and no native toolbar or floating assistant", async () => {
  const source = declaration(await read("Accounts/AccountSettingsView.swift"), "AccountSettingsView");
  assert.equal((source.match(/SettingsBackButton\(\)/g) ?? []).length, 1);
  assert.match(source, /\.toolbar\(\.hidden, for: \.navigationBar\)/);
  assert.match(source, /\.navigationBarBackButtonHidden\(\)/);
  assert.match(source, /\.fontDesign\(\.rounded\)\.fontWeight\(\.black\)/);
  for (const action of ["Sign In", "Add Account", "Log Out", "Delete Account", "Name", "Contact Email"]) assert.ok(source.includes(`"${action}"`));
  assert.match(source, /try await accounts\.deleteCurrentAccount\(\)[\s\S]*?accountDeleted = true/);
  assert.match(source, /\.alert\("Penned Account Deleted"/);
  assert.match(source, /Button\("Manage Apple Account"\).*openURL/);
  assert.doesNotMatch(source, /\bLColors\b|\bLSpacing\b|rainbow|assistant|ToolbarItem|Not available yet/);
  const settings = await read("Spaces/PennedSettingsView.swift");
  assert.match(settings, /if setting == \.account \{\s*AccountSettingsView\(\)\s*\} else \{/);
});

test("account startup, account-only local persistence and cloud storage cannot rewrite the document library", async () => {
  const app = await read("VellixApp.swift");
  assert.match(app, /@StateObject private var accounts = AppState\(\)/);
  assert.match(app, /ContentView\(\)\.environmentObject\(environment\)\.environmentObject\(accounts\)/);
  assert.match(app, /await accounts\.bootstrap\(\)\?\.value/);
  for (const notification of ["credentialRevokedNotification", "CKAccountChanged"]) assert.ok(app.includes(notification));
  const storage = await read("Accounts/AccountPersistence.swift");
  assert.match(storage, /Schema\(\[AuthUser\.self\]\)/);
  assert.match(storage, /Accounts\.store/);
  assert.match(storage, /cloudKitDatabase: \.none/);
  const state = await read("Data/AppState.swift");
  assert.doesNotMatch(state, /AppDatabase|DocumentRepository|deleteSpace|deleteDocument|report-conversation|ReportConversation/);
  const cloud = await read("Services/AccountCloudStore.swift");
  assert.match(cloud, /iCloud\.im\.lystaria\.Penned/);
  assert.match(cloud, /privateCloudDatabase/);
  assert.match(cloud, /PennedAccountProfile/);
  assert.doesNotMatch(cloud, /publicCloudDatabase|DocumentRecord|documents|setValue\(/);
});

test("account controls use only existing Penned asset names", async () => {
  for (const asset of ["profilewavy", "imagesign", "pencil", "dooropen", "addwavy", "arrowsprofile", "checkwavy", "cloudie", "luvmail", "sendbutton"]) {
    await readFile(new URL(`Assets.xcassets/${asset}.imageset/Contents.json`, root));
  }
});

test("email OTP keeps shared fields, native Apple authorization and cancellable code stages", async () => {
  const source = await read("Accounts/SignInView.swift");
  for (const title of ["Continue with Email", "Email address", "Verification code", "Send Verification Code", "Verify and Continue", "Resend Code"]) assert.ok(source.includes(`"${title}"`));
  assert.match(source, /\.textContentType\(\.oneTimeCode\)/);
  assert.match(source, /\.onDisappear \{ cancelEmail\(\) \}/);
  assert.match(source, /emailTask\?\.cancel\(\)/);
  assert.match(source, /appState\.cancelEmailSignIn\(attempt: attempt\)/);
  assert.doesNotMatch(source, /SecureField|password|LColors|LSpacing/);
});

test("email SDK sessions use separate native Keychain namespaces instead of a global session", async () => {
  const source = await read("Services/SupabaseEmailAuth.swift");
  assert.match(source, /import Supabase/);
  assert.match(source, /PennedAuthKeychainStorage\(service: \$0\)/);
  assert.match(source, /storage \?\? KeychainLocalStorage\(service: service\)/);
  assert.match(source, /clients: \[AccountIdentity: Entry\]/);
  assert.match(source, /autoRefreshToken: false/);
  assert.match(source, /ensurePersisted/);
  assert.match(source, /auth\.verifyOTP\(email: email, token: code, type: \.email\)/);
  assert.match(source, /auth\.signOut\(scope: \.local\)/);
  assert.doesNotMatch(source, /UserDefaults|\.auth\.admin|\.from\(/);
});

test("native auth storage normalizes only missing Keychain items and retains real failure checks", async () => {
  const source = await read("Services/SupabaseEmailAuth.swift");
  const storage = declaration(source, "PennedAuthKeychainStorage");
  assert.match(storage, /SecItemCopyMatching\(query as CFDictionary, &result\)/);
  assert.match(storage, /SecItemDelete\(query as CFDictionary\)/);
  assert.match(storage, /if status == errSecItemNotFound \{ return nil \}/);
  assert.match(storage, /guard status == errSecSuccess, let data else \{ throw AccountError\.keychainUnavailable \}/);
  assert.match(storage, /status == errSecSuccess \|\| status == errSecItemNotFound/);
  assert.match(storage, /kSecAttrService as String: service, kSecAttrAccount as String: key/);
  assert.match(source, /catch \{ recordFailure\(\); throw error \}/);
});

test("email configuration is centralized and cannot accept a server key", async () => {
  const source = await read("Accounts/SupabaseConfiguration.swift");
  assert.match(source, /values\["SUPABASE_URL"\]/);
  assert.match(source, /values\["SUPABASE_PUBLISHABLE_KEY"\]/);
  assert.match(source, /key\.hasPrefix\("sb_publishable_"\)/);
  assert.match(source, /throw EmailAuthError\.configurationMissing/);
  const plist = await read("Resources/LaunchInfo.plist");
  assert.match(plist, /<key>SUPABASE_URL<\/key>/);
  assert.match(plist, /<key>SUPABASE_PUBLISHABLE_KEY<\/key>/);
  assert.match(plist, /<string>\$\(SUPABASE_URL\)<\/string>/);
  assert.match(plist, /<string>\$\(SUPABASE_PUBLISHABLE_KEY\)<\/string>/);
  assert.doesNotMatch(plist, /SUPABASE_SECRET|SERVICE_ROLE/);
});

test("both app build configurations inherit the dedicated Supabase xcconfig without replacing build settings", async () => {
  const config = await read("Configuration/Supabase.xcconfig");
  assert.match(config, /^SUPABASE_URL = https:\/\$\(\)\/\S+$/m);
  assert.match(config, /^SUPABASE_PUBLISHABLE_KEY = \S+$/m);
  const projectPath = fileURLToPath(new URL("../Vellix.xcodeproj/project.pbxproj", root));
  const project = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", projectPath], { encoding: "utf8" }));
  const reference = Object.entries(project.objects).find(([, value]) => value.isa === "PBXFileReference" && value.path?.endsWith("Supabase.xcconfig"))?.[0];
  assert.ok(reference);
  for (const configuration of ["CFA16D89301AC183007825F0", "CFA16D8A301AC183007825F0"]) {
    const target = project.objects[configuration];
    assert.equal(target.baseConfigurationReference, reference);
    assert.ok(target.buildSettings);
    assert.equal(target.buildSettings.CODE_SIGN_ENTITLEMENTS, "Vellix/Vellix.entitlements");
  }
  assert.match(await read("Services/SupabaseEmailAuth.swift"), /self\.configuration = configuration \?\? \{ try \.load\(\) \}/);
});

test("saved-account provider labels and profile changes use provider-aware identities", async () => {
  const source = await read("Accounts/AccountSettingsView.swift");
  assert.match(source, /user\.providerName/);
  assert.match(source, /user\.authenticationEmail/);
  assert.match(source, /currentAccountIdentity == userID/);
  assert.doesNotMatch(source, /currentAppleUserId/);
  assert.match(await read("Data/AppState.swift"), /guard currentUser\?\.isApple == true else \{ return \}/);
});

test("email remote deletion requires server confirmation and retains retryable iCloud cleanup", async () => {
  const source = await read("Data/AppState.swift");
  assert.match(source, /try await auth\.deleteEmailAccount\(id\)[\s\S]*?user\.remoteAuthDeleted = true[\s\S]*?try await cloud\.delete\(identity: id/);
  assert.match(source, /status = \.deletionPending\(user\)/);
  assert.doesNotMatch(source, /AppDatabase|DocumentRepository|deleteDocument|deleteSpace/);
});

test("the presentation surface routes through the shared native backdrop without simulated blur or opaque fill", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  assert.match(declaration(source, "PennedSheetPresentation"), /\.pennedSheetBackdrop\(\)/);
  assert.match(source, /\.presentationCornerRadius\(PennedSheetStyle\.cornerRadius\)/);
  assert.match(source, /\.preferredColorScheme\(\.dark\)/);
  assert.match(source, /\.scrollContentBackground\(\.hidden\)/);
  assert.doesNotMatch(source, /\.blur\(|LinearGradient|AngularGradient|\.background\(Color\.black/);
  assert.doesNotMatch(source, /\.presentationDetents|\.presentationDragIndicator|\.interactiveDismissDisabled/);
});

test("iOS 26.1 sheets put the adjustable blur in the actual presentation background without a second material", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  const native = declaration(source, "PennedSheetBackdrop");
  assert.match(native, /UIColorEffect\(color: \.clear\)/);
  assert.match(native, /sheet\.backgroundEffect = transparentBase/);
  assert.match(native, /for detent in sheet\.detents where detent\.backgroundEffect !== transparentBase/);
  assert.match(native, /detent\.backgroundEffect = transparentBase/);
  assert.doesNotMatch(native, /sheet\.detents\s*=|selectedDetentIdentifier|\.delegate\s*=|\.alpha\s*=|\.opacity\(/);
  assert.doesNotMatch(native, /UIVisualEffectView|UIGlassEffect|UIBlurEffect|\.glassEffect\(/);
  const routing = source.slice(source.indexOf("@ViewBuilder fileprivate func pennedSheetBackdrop"), source.indexOf("func pennedSheet<"));
  assert.match(routing, /#if os\(iOS\) && !targetEnvironment\(macCatalyst\)/);
  assert.match(routing, /if #available\(iOS 26\.1, \*\) \{/);
  const currentIOS = routing.slice(routing.indexOf("if #available"), routing.indexOf("} else {"));
  assert.match(currentIOS, /PennedSheetBackdrop\(\)/);
  assert.match(currentIOS, /\.presentationBackground\s*\{\s*PennedSheetBlurSurface\(\)\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)\s*\.ignoresSafeArea\(\.container\)/);
  assert.doesNotMatch(currentIOS, /presentationBackground\(/);
  assert.match(routing, /else \{\s*presentationBackground\(\.ultraThinMaterial\)/);
});

test("backdrop resolution stays inside the nearest presented sheet and clears only its backing containers", async () => {
  const native = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetBackdrop");
  assert.match(native, /var candidate = parent/);
  assert.match(native, /presenter\.presentedViewController === controller/);
  assert.match(native, /guard let sheet = controller\.presentationController as\? UISheetPresentationController else \{ return \}/);
  assert.match(native, /candidate = controller\.parent/);
  assert.match(native, /surface\.backgroundColor = \.clear/);
  assert.match(native, /surface\.isOpaque = false/);
  assert.doesNotMatch(native, /presenter\.view|presentingViewController\?\.view|superview|subviews|connectedScenes|keyWindow/);
});

test("backdrop updates are lifecycle-driven and idempotent, without polling or repeated effect allocation", async () => {
  const native = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetBackdrop");
  assert.match(native, /private static let transparentBase = UIColorEffect\(color: \.clear\)/);
  assert.match(native, /sheet\.backgroundEffect !== transparentBase/);
  assert.match(native, /detent\.backgroundEffect !== transparentBase/);
  for (const callback of ["updateUIViewController", "didMove", "viewWillAppear", "viewDidAppear", "viewWillLayoutSubviews"]) {
    assert.match(native, new RegExp(`${callback}[\\s\\S]*?applyBackdrop\\(\\)`));
  }
  assert.doesNotMatch(native, /asyncAfter|Timer|CADisplayLink|DispatchQueue|Task\s*\{|NotificationCenter|\.observe\(/);
});

test("blur intensity is native effect interpolation, not glass replacement, opacity, or private radius manipulation", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  const blur = declaration(source, "PennedSheetBlurSurface");
  assert.match(source, /static let blurIntensity: CGFloat = 0\.35/);
  assert.match(blur, /final class BlurView: UIVisualEffectView/);
  assert.match(blur, /UIBlurEffect\(style: \.systemUltraThinMaterialLight\)/);
  assert.match(blur, /super\.init\(effect: nil\)/);
  assert.match(blur, /UIViewPropertyAnimator\(duration: 1, curve: \.linear\)/);
  assert.match(blur, /self\.effect = self\.blur/);
  assert.match(blur, /animation\.scrubsLinearly = true/);
  assert.match(blur, /animation\.pausesOnCompletion = true/);
  assert.match(blur, /animation\.startAnimation\(\)\s*animation\.pauseAnimation\(\)\s*animation\.fractionComplete = intensity/);
  assert.match(blur, /intensity\.isFinite \? min\(1, max\(0, intensity\)\)/);
  assert.doesNotMatch(blur, /UIGlassEffect|UIColorEffect|\.alpha\s*=|\.opacity\(|\.blur\(|setValue\(|value\(forKey:|blurRadius|CAFilter|CIFilter/);
});

test("the partial-blur animator is retained, reused across ordinary layout, and cleaned up on removal", async () => {
  const blur = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetBlurSurface");
  assert.match(blur, /private var animator: UIViewPropertyAnimator\?/);
  assert.match(blur, /animator = animation/);
  assert.match(blur, /installedIntensity == intensity/);
  assert.match(blur, /animator\.state == \.active, !animator\.isRunning/);
  assert.match(blur, /abs\(animator\.fractionComplete - intensity\) < 0\.0001 \{ return \}/);
  assert.match(blur, /guard isPresentationReady, !updatingBlur/);
  assert.match(blur, /defer \{ updatingBlur = false \}/);
  assert.match(blur, /static func dismantleUIViewController[\s\S]*?controller\.blurView\.endPresentation\(\)/);
  assert.match(blur, /if window == nil \{ endPresentation\(\) \}/);
  assert.match(blur, /if animator\?\.state == \.active \{ animator\?\.stopAnimation\(true\) \}/);
  assert.doesNotMatch(blur, /override func draw|asyncAfter|Timer|CADisplayLink|DispatchQueue|Task\s*\{/);
});

test("blur reconfiguration handles foreground and contrast changes and respects Reduce Transparency", async () => {
  const blur = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetBlurSurface");
  for (const environment of ["scenePhase", "accessibilityReduceTransparency", "colorSchemeContrast"]) {
    assert.match(blur, new RegExp(`@Environment\\(\\\\\\.${environment}\\)`));
  }
  assert.match(blur, /reduceTransparency \? 1 : intensity/);
  assert.match(blur, /phase == \.active && self\.phase != \.active/);
  assert.match(blur, /contrast != self\.contrast/);
  assert.match(blur, /if intensity == 1 \{\s*effect = blur/);
  assert.match(blur, /guard isPresentationReady, !updatingBlur, window != nil, bounds\.width > 0, bounds\.height > 0/);
});

test("initial blur waits for the actual appearance hierarchy and rebinds after presentation", async () => {
  const blur = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetBlurSurface");
  assert.match(blur, /struct PennedSheetBlurSurface: UIViewControllerRepresentable/);
  assert.match(blur, /override func loadView\(\) \{ view = blurView \}/);
  assert.match(blur, /private var isPresentationReady = false/);
  assert.match(blur, /override func viewIsAppearing[\s\S]*?super\.viewIsAppearing\(animated\)\s*blurView\.refreshForAppearance\(\)/);
  assert.match(blur, /override func viewDidAppear[\s\S]*?super\.viewDidAppear\(animated\)[\s\S]*?blurView\.refreshForAppearance\(\)/);
  assert.match(blur, /func refreshForAppearance\(\) \{\s*isPresentationReady = true\s*updateBlur\(force: true\)/);
  assert.match(blur, /func endPresentation\(\) \{\s*isPresentationReady = false\s*removeBlur\(\)/);
  assert.doesNotMatch(blur, /userDidTakeScreenshot|drawHierarchy|snapshotView|layer\.render|asyncAfter|Task\.sleep|CATransaction\.flush/);
});

test("the native sheet base is rechecked after appearance and size-transition completion", async () => {
  const native = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetBackdrop");
  assert.match(native, /override func viewDidAppear[\s\S]*?super\.viewDidAppear\(animated\)\s*applyBackdrop\(\)/);
  assert.match(native, /override func viewWillTransition/);
  assert.match(native, /coordinator\.animate\(alongsideTransition: nil\)[\s\S]*?self\.viewIfLoaded\?\.window != nil[\s\S]*?self\.applyBackdrop\(\)/);
  assert.doesNotMatch(native, /userDidTakeScreenshot|drawHierarchy|snapshotView|asyncAfter|Task\.sleep/);
});

test("resizing refreshes the settled blur without delegates, polling, or fixed delays", async () => {
  const blur = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetBlurSurface");
  assert.match(blur, /override func viewWillTransition/);
  assert.match(blur, /coordinator\.animate\(alongsideTransition: nil\)[\s\S]*?self\.viewIfLoaded\?\.window != nil[\s\S]*?self\.blurView\.refreshForAppearance\(\)/);
  assert.doesNotMatch(blur, /\.delegate\s*=|asyncAfter|Timer|CADisplayLink|DispatchQueue|Task\.sleep/);
});

test("SwiftUI interactive glass stays limited to the grouped top-right close/action controls", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  assert.match(source, /GlassEffectContainer\(spacing: 12\)/);
  assert.match(source, /\.buttonStyle\(\.glassProminent\)\.buttonBorderShape\(\.capsule\)/);
  assert.match(source, /glassEffect\(\.regular\.interactive\(\), in: \.circle\)/);
  assert.match(source, /#available\(iOS 26, macOS 26, \*\)/);
  assert.match(source, /LibraryIcon\(name: "xmarkwavy"/);
  assert.match(source, /\.safeAreaInset\(edge: \.top/);
  assert.doesNotMatch(source, /\.safeAreaInset\(edge: \.bottom/);
  assert.match(source, /\.frame\(maxWidth: \.infinity, alignment: \.trailing\)/);
  assert.match(source, /HStack\(alignment: \.top, spacing: 16\)/);
  assert.match(source, /\.environment\(\\\.editMode, \$editMode\)/);
});

test("the tag action sheet shares its first action row with close instead of reserving an empty header", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  assert.match(source, /func pennedSheet<Header: View>\(header: Header/);
  assert.match(source, /leading: header, headerBottomPadding: 0/);
  assert.doesNotMatch(source, /header: \(\) -> Header/);
  const tag = declaration(await read("Tags/TagEditorIntegration.swift"), "TagActionsSheet");
  assert.match(tag, /\.pennedSheet\(\s*header: action\("Go to Tag"/);
  const header = tag.slice(tag.indexOf(".pennedSheet("));
  assert.match(header, /action\("Go to Tag", icon: "hashtagwavy"\)/);
  assert.doesNotMatch(tag.slice(0, tag.indexOf(".pennedSheet(")), /action\("Go to Tag"/);
  assert.match(tag, /compactHeight: CGFloat \{ min\(460, actionHeight \* \(locked \? 1 : 3\) \+ 34\) \}/);
  assert.match(tag, /\.padding\(\.horizontal, 20\)/);
  for (const icon of ["hashtagwavy", "repeatarrows", "text"]) assert.match(tag, new RegExp(`icon: "${icon}"`));
});

test("collection management has Done and close without the redundant Edit button, retaining row actions", async () => {
  const source = declaration(await read("Collections/CollectionViewSheets.swift"), "CollectionManagementSheet");
  assert.doesNotMatch(source, /EditButton\(/);
  assert.match(source, /Button\("Done"\)/);
  assert.match(source, /close: \{ dismiss\(\) \}/);
  assert.match(source, /store\.repository\.rename\(collectionID: collectionID, name: name\)/);
  for (const action of ["Edit View", "Move Up", "Move Down", "Delete View"]) {
    assert.ok(source.includes(`Button("${action}"`));
  }
});

test("changing the field material leaves the light sheet blur and intensity unchanged", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  const blur = declaration(source, "PennedSheetBlurSurface");
  assert.match(blur, /var style: UIBlurEffect\.Style = \.systemUltraThinMaterialLight/);
  assert.match(blur, /var intensity: CGFloat = PennedSheetStyle\.blurIntensity/);
  assert.match(source, /static let blurIntensity: CGFloat = 0\.35/);
  assert.match(blur, /controller\.blurView\.configure\(style: style, intensity: reduceTransparency \? 1 : intensity/);
  assert.match(blur, /if intensity == 1 \{\s*effect = blur\s*\} else if intensity > 0 \{\s*let animation = UIViewPropertyAnimator/);
  assert.match(blur, /let changed = style != self\.style \|\| fraction != self\.intensity/);
  assert.match(blur, /if style != self\.style \{\s*self\.style = style\s*blur = UIBlurEffect\(style: style\)/);
  assert.match(blur, /updateBlur\(force: changed\)/);
  const routing = source.slice(source.indexOf("@ViewBuilder fileprivate func pennedSheetBackdrop"), source.indexOf("func pennedSheet<"));
  assert.match(routing, /PennedSheetBlurSurface\(\)/);
  assert.doesNotMatch(routing, /systemUltraThinMaterialDark/);
});

test("collection fields delegate to the universal row surface without a second form background", async () => {
  const source = await read("Collections/CollectionPropertySheets.swift");
  const rows = source.slice(source.indexOf("func collectionFormRows"), source.indexOf("@ViewBuilder func collectionKeyboard"));
  assert.match(rows, /showsSeparator: Bool = false/);
  assert.match(rows, /pennedSheetRows\(showsSeparator: showsSeparator\)/);
  assert.doesNotMatch(rows, /Color\.|\.opacity\(|\.background\(|UIBlurEffect|\.glassEffect\(|presentationBackground/);
  assert.match(source, /func collectionForm\(compact: Bool = false\) -> some View/);
  assert.match(source, /else \{\s*scrollContentBackground\(\.hidden\)\s*\}/);
});

test("compact collection forms size rows from content rather than imposing control-height floors", async () => {
  const properties = await read("Collections/CollectionPropertySheets.swift");
  const layout = properties.slice(properties.indexOf("func collectionForm("), properties.indexOf("func collectionFormRows"));
  assert.match(layout, /compact: Bool = false/);
  assert.match(layout, /if compact \{/);
  assert.match(layout, /\.environment\(\\\.pennedSheetCompactRows, true\)/);
  assert.match(layout, /\.environment\(\\\.defaultMinListRowHeight, 0\)/);
  assert.match(layout, /\.environment\(\\\.defaultMinListHeaderHeight, 0\)/);
  assert.match(layout, /\.listSectionSpacing\(VellixSpacing\.md\)/);
  assert.match(layout, /\.contentMargins\(\.top, 0, for: \.scrollContent\)/);
  assert.match(layout, /\.buttonStyle\(\.borderless\)/);
  assert.match(layout, /\.textFieldStyle\(\.plain\)/);
  assert.match(layout, /\.fontDesign\(\.rounded\)\.fontWeight\(\.black\)/);
  assert.doesNotMatch(layout, /\.listRowInsets|\.offset\(|\.padding\(|\.frame\(height:|presentationBackground|UIBlurEffect|\.background\(/);
  const source = await read("Collections/CollectionViewSheets.swift");
  const management = declaration(source, "CollectionManagementSheet");
  assert.match(management, /\.collectionForm\(compact: true\)/);
  assert.match(management, /LibraryIcon\(name: "dotswavy", size: 22\)\.frame\(width: 44\)/);
  assert.match(management, /HStack\(spacing: 12\)/);
  assert.match(management, /HStack\(spacing: 10\)/);
  assert.match(management, /TextField\("Collection name", text: \$name\)/);
  assert.equal((management.match(/\.frame\(maxWidth: \.infinity, alignment: \.leading\)\.contentShape\(Rectangle\(\)\)/g) ?? []).length, 4);
  assert.doesNotMatch(management, /minHeight:|height:|\.offset\(|\.padding\(/);
  assert.doesNotMatch(source.slice(source.indexOf("struct CollectionAddViewSheet:")), /collectionForm\(compact: true\)/);
});

test("compact insets are applied by shared row styling to actual row content, not only the outer Form", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  assert.match(source, /struct PennedSheetCompactRowsKey: EnvironmentKey \{\s*static let defaultValue = false/);
  assert.match(source, /static let compactRowVerticalInset: CGFloat = 9/);
  const insets = declaration(source, "PennedSheetRowInsets");
  assert.match(insets, /@Environment\(\\\.pennedSheetCompactRows\)/);
  assert.match(insets, /var isHeader = false/);
  assert.match(insets, /if compact \{\s*content\.listRowInsets\(EdgeInsets\(top: isHeader \? 0 : PennedSheetStyle\.compactRowVerticalInset,/);
  assert.match(insets, /leading: VellixSpacing\.lg,\s*bottom: isHeader \? VellixSpacing\.xs : PennedSheetStyle\.compactRowVerticalInset,\s*trailing: VellixSpacing\.lg/);
  assert.match(insets, /else \{\s*content\s*\}/);
  assert.doesNotMatch(insets, /\.frame\(|\.scaleEffect\(|\.offset\(|\.background\(|UIBlurEffect|\.font/);
  const rows = source.slice(source.indexOf("@ViewBuilder func pennedSheetRows"), source.indexOf("func pennedSheetSectionHeader"));
  assert.match(rows, /\.modifier\(PennedSheetRowInsets\(\)\)/);
  const spacing = await read("Resources/VellixDesignSystem.swift");
  for (const [token, size] of [["xs", 6], ["md", 14], ["lg", 20]]) {
    assert.match(spacing, new RegExp(`static let ${token}: CGFloat = ${size}`));
  }
});

test("collection section labels explicitly control their gap to fields without resizing the sheet header", async () => {
  const management = declaration(await read("Collections/CollectionViewSheets.swift"), "CollectionManagementSheet");
  for (const label of ["Collection", "Views", "Shared Fields"]) {
    assert.ok(management.includes(`Text("${label}").pennedSheetSectionHeader()`));
  }
  const source = await read("Resources/PennedSheetStyle.swift");
  assert.match(source, /func pennedSheetSectionHeader\(\) -> some View \{\s*modifier\(PennedSheetRowInsets\(isHeader: true\)\)/);
  const header = declaration(source, "PennedSheetChrome<Actions: View, Leading: View>");
  assert.match(header, /minHeight: 44, alignment: \.leading/);
  assert.match(source, /LibraryIcon\(name: "xmarkwavy", size: 23\)\.frame\(width: 44, height: 44\)/);
});

test("all field surfaces use the copied material with one dark-gray tint and no content resizing", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  const field = declaration(source, "PennedSheetFieldBackground");
  assert.match(source, /static let fieldTint = Color\(white: 0\.2\)/);
  assert.match(field, /PennedFrostedMaterial\(tint: PennedSheetStyle\.fieldTint, cornerRadius: cornerRadius\)/);
  assert.match(field, /\.allowsHitTesting\(false\)\.accessibilityHidden\(true\)/);
  assert.doesNotMatch(field, /PennedSheetBlurSurface|UIBlurEffect|ultraThinMaterial|PennedFrostedCard|\.padding\(|\.frame\(|\.opacity\(|\.blur\(|presentationBackground/);
  assert.match(source, /func pennedSheetField\(cornerRadius: CGFloat = 8\)[\s\S]*?background \{ PennedSheetFieldBackground\(cornerRadius: cornerRadius\) \}/);
  const native = declaration(source, "PennedSheetBlurSurface");
  assert.match(native, /controller\.blurView\.layer\.cornerRadius = max\(0, cornerRadius\)/);
  assert.match(native, /controller\.blurView\.layer\.cornerCurve = \.continuous/);
  assert.match(native, /controller\.blurView\.clipsToBounds = clipsToBounds \|\| cornerRadius > 0/);
  assert.doesNotMatch(native, /\.clipShape\(|\.mask\(|superview/);
});

test("PennedFrostedMaterial retains the source's tinted Liquid Glass, pigment and surface frost recipe", async () => {
  const source = await read("Resources/PennedFrostedCard.swift");
  const material = declaration(source, "PennedFrostedMaterial");
  assert.match(material, /let tint: Color/);
  assert.match(material, /var cornerRadius: CGFloat = 17/);
  assert.match(material, /RoundedRectangle\(cornerRadius: cornerRadius, style: \.continuous\)/);
  assert.match(material, /coloredField\s*Color\.clear\s*\.glassEffect\(\.regular\.tint\(tint\.opacity\(0\.22\)\), in: shape\)\s*frostClouds/);
  assert.match(material, /\.clipShape\(shape\)/);
  assert.equal((material.match(/GeometryReader/g) ?? []).length, 2);
  assert.equal((material.match(/Ellipse\(\)/g) ?? []).length, 6);
  for (const radius of [28, 26, 24, 22]) assert.ok(material.includes(`.blur(radius: ${radius})`));
  for (const opacity of ["0.45", "0.16", "0.11", "0.08"]) assert.ok(material.includes(`Color.white.opacity(${opacity})`));
  assert.match(material, /tint\.opacity\(0\.5\)/);
  assert.match(material, /VellixSurface\.appBackground\.opacity\(0\.4\)/);
  assert.match(material, /\.scaleEffect\(1\.15\)/);
  assert.doesNotMatch(material, /content\(\)|\.padding\(|minHeight|presentationBackground|UIBlurEffect/);
  assert.doesNotMatch(source, /VoxiverseColor|struct Voxiverse|import UIKit/);
});

test("PennedFrostedCard preserves the source wrapper's configurable API without adding field padding", async () => {
  const source = await read("Resources/PennedFrostedCard.swift");
  const card = declaration(source, "PennedFrostedCard<Content: View>");
  for (const property of ["let tint: Color", "var cornerRadius: CGFloat = 17", "var contentPadding: CGFloat = 15", "var minHeight: CGFloat? = nil", "var alignment: Alignment = .leading", "@ViewBuilder var content: () -> Content"]) {
    assert.ok(card.includes(property), property);
  }
  assert.match(card, /content\(\)\s*\.padding\(contentPadding\)\s*\.frame\(maxWidth: \.infinity, minHeight: minHeight, alignment: alignment\)\s*\.background\(PennedFrostedMaterial\(tint: tint, cornerRadius: cornerRadius\)\)/);
  assert.match(card, /\.shadow\(color: VellixSurface\.appBackground\.opacity\(0\.5\), radius: 8, y: 5\)/);
  assert.match(card, /\.shadow\(color: tint\.opacity\(0\.32\), radius: 6\)/);
  assert.doesNotMatch(card, /\.blur\(/);
  const harness = await readFile(new URL("../Scripts/test-collections.mjs", root), "utf8");
  assert.match(harness, /"Resources\/PennedFrostedCard\.swift"/);
});

test("inline property options contain one unchanged shared material per row rather than one large group surface", async () => {
  const source = await read("Editor/InlinePropertyEditorSheet.swift");
  const options = source.slice(source.indexOf("private var optionsSection:"), source.indexOf("private var valueEditor:"));
  assert.match(options, /VStack\(spacing: 10\) \{\s*ForEach\(property\.options\) \{ option in/);
  assert.match(options, /Button \{ editingOptionID = option\.id \} label:[\s\S]*?\.padding\(\.horizontal, 16\)\s*\.padding\(\.vertical, 10\)\s*\.contentShape\(Rectangle\(\)\)\s*\.pennedSheetField\(cornerRadius: 16\)\s*\}/);
  assert.equal((options.match(/\.pennedSheetField\(/g) ?? []).length, 1);
  assert.doesNotMatch(options, /PennedSheetFieldDivider|\.glassEffect\(|PennedFrostedMaterial\(|\.blur\(/);
  for (const feature of ["InlinePropertyOptionPill(option: option)", "PropertyOptionDragHandle()", ".draggable(option.id)", ".dropDestination(for: String.self)", ".contextMenu", '.accessibilityAction(named: "Move up")', '.accessibilityAction(named: "Move down")']) {
    assert.ok(options.includes(feature), feature);
  }
});

test("property sheet dismissal keeps its existing document and editability guards before requesting focus", async () => {
  const source = await read("Editor/DocumentEditorView.swift");
  assert.match(source, /\.sheet\(item: \$propertyEditorRequest, onDismiss: resumeEditingAfterProperty\)/);
  const resume = source.slice(source.indexOf("private func resumeEditingAfterProperty()"), source.indexOf("private func dismissBlockDeletion()"));
  for (const guard of ["target.documentID == model.documentID", "!isEditorLocked", "selectionMode == .off", "environment.selectedDocumentID == model.documentID", "model.session.renderedDocumentID == model.documentID"]) assert.ok(resume.includes(guard), guard);
  assert.match(resume, /model\.session\.focusAfterInlineProperty\(blockID: target\.blockID\)/);
});

test("field separators use native styling above the blur, safely inside row bounds", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  const divider = declaration(source, "PennedSheetFieldDivider");
  assert.match(divider, /@Environment\(\\\.pixelLength\)/);
  assert.match(divider, /Divider\(\)\.frame\(height: pixelLength\)/);
  assert.doesNotMatch(divider, /Rectangle\(|\.fill\(|\.white|\.opacity\(|FillStyle/);
  assert.match(divider, /\.allowsHitTesting\(false\)\.accessibilityHidden\(true\)/);
  const row = declaration(source, "PennedSheetRowBackground");
  assert.match(row, /surface\s*\.overlay\(alignment: \.bottom\)/);
  assert.match(row, /PennedSheetFieldBackground\(cornerRadius: 0\)/);
  assert.match(row, /if showsSeparator/);
  assert.match(row, /PennedSheetFieldDivider\(\)\.padding\(\.horizontal, 20\)\.padding\(\.bottom, pixelLength\)/);
  const modifier = source.slice(source.indexOf("@ViewBuilder func pennedSheetRows"), source.indexOf("@ViewBuilder fileprivate func pennedSheetBackdrop"));
  assert.match(modifier, /showsSeparator: Bool = false/);
  assert.match(modifier, /if isSheet/);
  assert.match(modifier, /listRowBackground\(PennedSheetRowBackground\(showsSeparator: showsSeparator\)\)\s*\.listRowSeparator\(\.hidden\)/);
  assert.match(modifier, /else \{ self \}/);
});

test("Collection sections opt into shared backgrounds without replacing their native rows or approved dimensions", async () => {
  const source = declaration(await read("Collections/CollectionViewSheets.swift"), "CollectionManagementSheet");
  for (const id of ["collection-name", "collection-views", "collection-fields"]) {
    assert.equal((source.match(new RegExp(`pennedSheetSectionBackground\\("${id}"\\)`, "g")) ?? []).length, 1);
  }
  assert.match(source, /\.collectionForm\(compact: true\)\.pennedSheetGroupedSections\(\)/);
  assert.match(source, /Form \{/);
  assert.equal((source.match(/\.onMove/g) ?? []).length, 2);
  assert.doesNotMatch(source, /minHeight:|height:|\.padding\(|\.listRowInsets\(|\.offset\(/);
});

test("grouped rows provide transparent geometry probes instead of additional native blur layers", async () => {
  const row = declaration(await read("Resources/PennedSheetStyle.swift"), "PennedSheetRowBackground");
  const grouped = row.slice(row.indexOf("if let sectionBackgroundOwner"), row.indexOf("} else {", row.indexOf("if let sectionBackgroundOwner")));
  assert.match(grouped, /PennedSheetSectionRowProbe\(owner: sectionBackgroundOwner, sectionID: sectionBackgroundID\)/);
  assert.doesNotMatch(grouped, /PennedSheetFieldBackground|PennedSheetBlurSurface|UIBlurEffect/);
  assert.match(row, /else \{\s*PennedSheetFieldBackground\(cornerRadius: 0\)/);
  assert.match(row, /PennedSheetFieldDivider\(\)\.padding\(\.horizontal, 20\)\.padding\(\.bottom, pixelLength\)/);
});

test("one copied dark-gray material is retained per visible section behind the original Form cells", async () => {
  const source = await read("Resources/PennedSheetSectionBackground.swift");
  assert.match(source, /Dictionary\(grouping: rows, by: \\.sectionID\)/);
  assert.match(source, /if let existing = plane\.surfaces\[id\]/);
  assert.match(source, /plane\.surfaces\[id\] = surface/);
  assert.equal((source.match(/PennedFrostedMaterial\(/g) ?? []).length, 1);
  assert.match(source, /private final class Surface: UIView/);
  assert.match(source, /materialView = UIHostingConfiguration \{\s*PennedFrostedMaterial\(tint: PennedSheetStyle\.fieldTint, cornerRadius: 0\)/);
  assert.match(source, /\.environment\(\\\.colorScheme, \.dark\)/);
  assert.match(source, /\.margins\(\.all, 0\)\s*\.minSize\(width: 0, height: 0\)\s*\.background \{ Color\.clear \}\s*\.makeContentView\(\)/);
  assert.match(source, /materialView\.backgroundColor = \.clear/);
  assert.match(source, /materialView\.isUserInteractionEnabled = false/);
  assert.match(source, /if materialView\.frame != bounds \{ materialView\.frame = bounds \}/);
  assert.match(source, /list\.insertSubview\(plane, at: 0\)/);
  assert.match(source, /list\.sendSubviewToBack\(plane\)/);
  assert.match(source, /\.convert\(\$0\.bounds, to: list\)/);
  assert.match(source, /reduce\(first\.1\) \{ \$0\.union\(\$1\.1\) \}/);
  assert.match(source, /surface\.apply\(frame: frame, corners: corners\)/);
  assert.doesNotMatch(source, /UIVisualEffectView|UIBlurEffect|UIViewPropertyAnimator|\.opacity\(|\.alpha\s*=|\.blur\(|glassEffect|UIColor\.(?:black|gray)|probe\.frame\s*=|cell\.frame\s*=/);
});

test("section backgrounds copy native corner geometry without mutating cells or private UIKit classes", async () => {
  const source = await read("Resources/PennedSheetSectionBackground.swift");
  assert.match(source, /view\.effectiveRadius\(corner: corner\)/);
  assert.match(source, /view\.layer\.maskedCorners\.contains\(layerCorner\)/);
  assert.match(source, /let top = first\.0\.nativeCorners\(in: list\)/);
  assert.match(source, /let bottom = last\.0\.nativeCorners\(in: list\)/);
  assert.match(source, /cornerConfiguration = \.corners\(topLeftRadius: \.fixed\(Double\(corners\.topLeft\)\)/);
  assert.match(source, /clipsToBounds = true/);
  assert.doesNotMatch(source, /NSClassFromString|value\(forKey|setValue\(|class_get|_UI|\.mask\s*=|cornerRadius\s*=|\.delegate\s*=/);
});

test("shared background geometry updates and cleanup use native lifecycle callbacks without logs or polling", async () => {
  const source = await read("Resources/PennedSheetSectionBackground.swift");
  assert.match(source, /weak var owner: PennedSheetSectionBackgroundOwner\?/);
  assert.match(source, /weak var view: Probe\?/);
  assert.match(source, /static func dismantleUIView[\s\S]*?view\.owner\?\.remove\(view\)/);
  assert.match(source, /override func didMoveToWindow/);
  assert.match(source, /override func layoutSubviews/);
  assert.match(source, /\$0\.isVisibleRow/);
  assert.match(source, /if list\.subviews\.first !== plane \{ list\.sendSubviewToBack\(plane\) \}/);
  assert.match(source, /list\.observe\(\\\.bounds\)/);
  assert.match(source, /list\.observe\(\\\.contentSize\)/);
  assert.match(source, /planes\.removeValue\(forKey: key\)\?\.detach\(\)/);
  assert.match(source, /geometryObservations\.forEach \{ \$0\.invalidate\(\) \}/);
  assert.match(source, /geometryObservations\.removeAll\(\)/);
  assert.match(source, /plane\.surfaces\.removeValue\(forKey: id\)\?\.removeFromSuperview\(\)/);
  assert.match(source, /planes\.removeValue\(forKey: ObjectIdentifier\(list\)\)/);
  assert.doesNotMatch(source, /asyncAfter|Timer|CADisplayLink|DispatchQueue|Task\s*\{|NotificationCenter|@Published|print\(|logger\.|os_log|snapshotView|drawHierarchy|CIFilter/);
});

test("Page Style removes the lower-left status footer without removing saved-style actions", async () => {
  const source = declaration(await read("Editor/DocumentStyleSheet.swift"), "DocumentStyleSheet");
  assert.doesNotMatch(source, /styleFooter|Created by you|Text\(match\?\.title \?\? "Custom Style"\)/);
  assert.match(source, /case \.overview:\s*ScrollView \{\s*overview\.frame\(height: 3 \* 116 \+ 2 \* 8\)/);
  assert.match(source, /scrollBounceBehavior\(\.basedOnSize\)/);
  assert.match(source, /Button\("Save"\)/);
  assert.match(source, /currentMatch/);
  assert.match(source, /environment\.documentStyles\.apply\(style, to: documentID\)/);
  assert.match(source, /galleryItem\(style, definition: value\)/);
});

test("the Space switcher puts search beside close and pins Create Space below the list", async () => {
  const source = declaration(await read("Spaces/PennedSettingsView.swift"), "SpacePickerSheet");
  assert.match(source, /\.pennedSheet\(header: searchField, closeDisabled: switching \|\| environment\.isSwitchingSpace, close: \{ dismiss\(\) \}\)/);
  assert.match(source, /\.safeAreaInset\(edge: \.bottom, spacing: 0\) \{\s*HStack \{\s*createSpaceButton/);
  assert.match(source, /private var searchField:[\s\S]*?TextField\("Open Space\.\.\."[\s\S]*?minHeight: 44\)\.pennedSheetField\(\)/);
  assert.match(source, /@ViewBuilder private var createSpaceButton/);
  assert.match(source, /button\.buttonStyle\(\.glassProminent\)\.buttonBorderShape\(\.capsule\)/);
  assert.equal((source.match(/Text\("Create Space"\)/g) ?? []).length, 1);
  const header = source.slice(source.indexOf(".pennedSheet("), source.indexOf(".presentationDragIndicator"));
  assert.doesNotMatch(header, /Create Space|createSpaceButton|\) \{/);
});

test("the compact Space switcher preserves filtering, scaling, switching and nested creation", async () => {
  const source = declaration(await read("Spaces/PennedSettingsView.swift"), "SpacePickerSheet");
  assert.match(source, /@ScaledMetric\(relativeTo: \.body\) private var rowHeight: CGFloat = 44/);
  assert.match(source, /\* rowHeight \+ 140/);
  const sizing = source.slice(source.indexOf("private var compactHeight"), source.indexOf("var body:"));
  assert.doesNotMatch(sizing, /query|spaces\.count/);
  assert.match(source, /query\.isEmpty \|\| \$0\.title\.localizedCaseInsensitiveContains\(query\)/);
  assert.match(source, /\.lineLimit\(2\)\.fixedSize\(horizontal: false, vertical: true\)/);
  assert.match(source, /\.presentationDetents\(\[\.height\(compactHeight\), \.large\]\)/);
  assert.match(source, /\.sheet\(isPresented: \$creating/);
  assert.match(source, /SpaceEditorSheet\(space: nil\)/);
  assert.match(source, /try await environment\.switchSpace\(to: space\.id\); dismiss\(\)/);
  assert.doesNotMatch(source, /foregroundStyle\(Color\.blue\)/);
});

test("foreground dimming and preview clipping do not mask or fade the native field blur", async () => {
  const icons = declaration(await read("Editor/DocumentEditorView.swift"), "VellixIconLibraryPicker");
  assert.match(icons, /\.opacity\(available \? 1 : 0\.45\)\s*\.pennedSheetField\(\)/);
  assert.doesNotMatch(icons, /\.disabled\(!available\)\.opacity\(/);
  const style = declaration(await read("Editor/DocumentStyleSheet.swift"), "DocumentStyleSheet");
  assert.match(style, /content\(\)\.frame\(width: width, height: 116\)\s*\.clipShape\(RoundedRectangle\(cornerRadius: 8\)\)\s*\.pennedSheetField\(\)/);
});

test("collection group dividers follow rows as they are added, removed, and reordered", async () => {
  const source = await read("Collections/CollectionViewSheets.swift");
  const management = declaration(source, "CollectionManagementSheet");
  assert.match(management, /ForEach\(snapshot\.views\)[\s\S]*?collectionFormRows\(showsSeparator: true\)/);
  assert.match(management, /ForEach\(snapshot\.fields\)[\s\S]*?collectionFormRows\(showsSeparator: true\)/);
  assert.match(management, /Text\("Add View"\)[\s\S]*?\}\.collectionFormRows\(\)/);
  assert.match(management, /Text\("Add Field"\)[\s\S]*?\}\.collectionFormRows\(\)/);
  const editor = declaration(source, "CollectionViewEditorSheet");
  assert.match(editor, /field\.id != orderedFields\.last\?\.id \|\| !hiddenFields\.isEmpty/);
  assert.match(editor, /field\.id != hiddenFields\.last\?\.id/);
});

const nativeFieldSheets = {
  "Attachments/AttachmentEditorSheet.swift": ["AttachmentEditorSheet"],
  "DailyNotes/TemplateComponentEditorSheet.swift": ["TemplateComponentEditorSheet"],
  "Documents/FolderLibraryViews.swift": ["FolderEditorSheet", "FolderDestinationPicker"],
  "Spaces/SpaceViews.swift": ["SpaceEditorSheet", "SpaceTransferSheet"],
  "Editor/CardThreeModeColorPicker.swift": ["CardThreeModeColorPicker"],
};
for (const [file, names] of Object.entries(nativeFieldSheets)) {
  for (const name of names) test(`${name} uses the universal native row field treatment`, async () => {
    const source = declaration(await read(file), name);
    if (name === "FolderDestinationPicker") {
      assert.match(source, /\.pennedSheetRows\(showsSeparator:/);
    } else assert.match(source, /\.pennedSheetRows\(/);
  });
}

const customFieldSheets = {
  "Editor/InlinePropertyEditorSheet.swift": ["InlinePropertyEditorSheet", "InlinePropertyOptionEditor"],
  "Editor/TaskEditorSheet.swift": ["TaskEditorSheet"],
  "Editor/TableEditorSheet.swift": ["TableEditorSheet"],
  "Editor/DocumentStyleSheet.swift": ["DocumentStyleSheet"],
  "Editor/CardBackdropSheet.swift": ["CardBackdropSheet"],
  "Editor/PageCardEditorSheet.swift": ["PageCardEditorSheet"],
  "Editor/CardPhotoSearchSheet.swift": ["CardPhotoSearchSheet"],
  "Editor/DocumentEditorView.swift": ["VellixIconLibraryPicker", "VellixBlockColorControls"],
  "Spaces/PennedSettingsView.swift": ["SpacePickerSheet"],
  "Calendar/CalendarEventDetailSheet.swift": ["CalendarEventDetailSheet"],
  "Tags/TagEditorIntegration.swift": ["TagSelectorSheet"],
  "Resources/PennedSheetStyle.swift": ["PennedSheetSearchField"],
};
for (const [file, names] of Object.entries(customFieldSheets)) {
  for (const name of names) test(`${name} uses the shared dark field surface`, async () => {
    const source = declaration(await read(file), name);
    if (name === "InlinePropertyOptionEditor") assert.match(source, /\.propertyConfigurationSurface\(/);
    else assert.match(source, /\.pennedSheetField\(/);
  });
}

test("sheet-only field styling does not change ordinary Daily Notes settings or Home content", async () => {
  const daily = await read("DailyNotes/DailyNotesSettingsView.swift");
  assert.match(daily, /pennedSheetRows\(showsSeparator: true, when: onSelected != nil\)/);
  assert.match(daily, /pennedSheetRows\(when: onSelected != nil\)/);
  assert.match(daily, /else \{ searchable\(text: text, prompt: "Templates"\) \}/);
  const home = await read("Documents/HomeView.swift");
  const sheet = home.slice(home.indexOf(".sheet(isPresented: $customizeHome)"), home.indexOf(".onAppear", home.indexOf(".sheet(isPresented: $customizeHome)")));
  for (const label of ["Document previews", "Starred", "Folders"]) assert.ok(sheet.includes(`Toggle("${label}"`));
  assert.equal((sheet.match(/\.pennedSheetRows\(/g) ?? []).length, 3);
});

for (const [file, names] of Object.entries(sheets).filter(([file]) => file.startsWith("Collections/"))) {
  for (const name of names) test(`${name} applies dark frosting to its own native form/list rows`, async () => {
    const source = declaration(await read(file), name);
    assert.match(source, /(?:Form|List) \{/);
    assert.match(source, /\.collectionFormRows\(\)/);
    assert.match(source, /\.collectionForm\((?:compact: true)?\)/);
    assert.doesNotMatch(source, /\.listRowBackground\(Color|\.background\(Color\.(?:black|gray)/);
  });
}

test("all sheet toggles inherit round asset thumbs and retain native accessibility and bindings", async () => {
  const source = await read("Resources/PennedSheetStyle.swift");
  assert.match(source, /\.toggleStyle\(PennedSheetToggleStyle\(\)\)/);
  assert.match(source, /configuration\.isOn\.toggle\(\)/);
  assert.match(source, /configuration\.isOn \? "checkwavy" : "xmarkwavy"/);
  assert.match(source, /in: Circle\(\)/);
  assert.match(source, /accessibilityReduceMotion/);
  assert.match(source, /\.accessibilityRepresentation\s*\{/);
  assert.match(source, /Toggle\(isOn: configuration\.\$isOn\)/);
  for (const icon of ["xmarkwavy", "checkwavy"]) {
    await readFile(new URL(`Assets.xcassets/${icon}.imageset/Contents.json`, root));
  }
});

for (const [file, names] of Object.entries(sheets)) {
  for (const name of names) test(`${name} uses the shared sheet and has no corner toolbar or opaque root`, async () => {
    const fileSource = await read(file);
    const source = declaration(fileSource, name) + (name === "AccountLibrarySheet" ? declaration(fileSource, "AccountLibraryPresentation") : "");
    assert.match(source, /\.pennedSheet\(/);
    assert.doesNotMatch(source, /\.toolbar\s*\{/);
    assert.doesNotMatch(source, /\.presentationBackground|\.presentationCornerRadius/);
    assert.doesNotMatch(source, /\.background\((?:VellixSurface\.(?:appBackground|sidebar|paperLifted)|Color\.black)\)/);
    assert.doesNotMatch(source, /\.background\(\.(?:ultraThin|thin|regular|thick)Material\)/);
  });
}

test("inline sheet presenters and shared forms do not hide the presentation material", async () => {
  for (const file of ["Documents/HomeView.swift", "Calendar/CalendarView.swift"]) {
    const source = await read(file);
    const sheet = source.slice(source.indexOf(".sheet("));
    assert.match(sheet, /\.pennedSheet\(/, fileURLToPath(new URL(file, root)));
  }
  const properties = await read("Collections/CollectionPropertySheets.swift");
  assert.match(properties, /func collectionForm\(compact: Bool = false\)[\s\S]*?scrollContentBackground\(\.hidden\)/);
  assert.doesNotMatch(properties, /scrollContentBackground\(\.hidden\)\.background\(/);
});

test("searches remain in the content when sheet navigation bars are hidden", async () => {
  for (const [file, name] of [["Documents/FolderLibraryViews.swift", "FolderDestinationPicker"], ["Editor/DocumentEditorView.swift", "VellixIconLibraryPicker"]]) {
    const source = declaration(await read(file), name);
    assert.match(source, /PennedSheetSearchField\(/);
    assert.doesNotMatch(source, /\.searchable\(/);
  }
  const daily = await read("DailyNotes/DailyNotesSettingsView.swift");
  assert.match(daily, /if onSelected != nil(?: \|\| isWorkspaceEmbedded)? \{ PennedSheetSearchField/);
  assert.match(daily, /else \{ searchable\(text: text, prompt: "Templates"\) \}/);
});
