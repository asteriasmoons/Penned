import { mkdtemp, mkdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = fileURLToPath(new URL("../", import.meta.url));
const workspace = await mkdtemp(join(tmpdir(), "penned-account-tests-"));
await mkdir(join(workspace, "Sources/Vellix"), { recursive: true });
await mkdir(join(workspace, "Tests/AccountTests"), { recursive: true });
await mkdir(join(workspace, "Sources/LegacyAccountFixture"), { recursive: true });
for (const path of ["Models/AuthUser.swift", "Data/AppState.swift", "Data/KeychainHelper.swift",
  "Accounts/AccountIdentity.swift", "Accounts/SupabaseConfiguration.swift", "Accounts/AccountPersistence.swift",
  "Services/EmailAuthentication.swift", "Services/SupabaseEmailAuth.swift", "Services/AuthService.swift", "Services/AccountCloudStore.swift",
  "Publishing/PublishingTypes.swift", "Publishing/PublishingClient.swift", "Publishing/PublishingAppleAuth.swift"]) {
  await symlink(join(root, "Vellix", path), join(workspace, "Sources/Vellix", path.replaceAll("/", "_")));
}
await symlink(join(root, "Vellix/VellixTests/AccountTests.swift"), join(workspace, "Tests/AccountTests/AccountTests.swift"));
await symlink(join(root, "Vellix/VellixTests/SupabaseAuthTests.swift"), join(workspace, "Tests/AccountTests/SupabaseAuthTests.swift"));
await symlink(join(root, "Tests/Publishing/PublishingAuthTests.swift"), join(workspace, "Tests/AccountTests/PublishingAuthTests.swift"));
await symlink(join(root, "Scripts/fixtures/LegacyAccountStore.swift"), join(workspace, "Sources/LegacyAccountFixture/LegacyAccountStore.swift"));
await writeFile(join(workspace, "Package.swift"), `// swift-tools-version:6.4
import PackageDescription
let package = Package(name: "PennedAccountTests", platforms: [.macOS("26.5")], dependencies: [
  .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.4")
], targets: [
  .executableTarget(name: "LegacyAccountFixture", swiftSettings: [.swiftLanguageMode(.v5)]),
  .target(name: "Vellix", dependencies: [.product(name: "Supabase", package: "supabase-swift")], swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-default-isolation", "MainActor"])]),
  .testTarget(name: "AccountTests", dependencies: ["Vellix"], swiftSettings: [.swiftLanguageMode(.v5)])
])
`);
// Native macOS domain tests only: no app, simulator, Apple authentication, or live CloudKit requests.
async function run(args, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn("swift", args, { stdio: "inherit", detached: true, env });
    const timer = setTimeout(() => { console.error("Account checks exceeded 600 seconds"); process.kill(-child.pid, "SIGKILL"); }, 600_000);
    child.on("error", error => { clearTimeout(timer); reject(error); });
    child.on("exit", (code, signal) => { clearTimeout(timer); resolve(code ?? (signal ? 124 : 1)); });
  });
}
const paths = ["--package-path", workspace, "--scratch-path", join(tmpdir(), "penned-account-tests-cache"), "-j", "4"];
const legacy = join(workspace, "LegacyAccounts");
const fixtureCode = await run(["run", ...paths, "LegacyAccountFixture", legacy]);
process.exitCode = fixtureCode || await run(["test", ...paths], { ...process.env, PENNED_LEGACY_ACCOUNT_STORE: legacy });
