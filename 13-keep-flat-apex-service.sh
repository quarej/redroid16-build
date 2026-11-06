#!/usr/bin/env bash
# VM .108: keep apexservice alive in flattened APEX mode, and report modules
# using their on-disk manifests without loop/DM. Normal updatable mode intact.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path
root = Path('/work/aosp/source/system/apex/apexd')
main = root / 'apexd_main.cpp'
service = root / 'apexservice.cpp'
a = main.read_text()
b = service.read_text()
old = '''    if (!has_subcommand) {
      if (booting) android::apex::OnAllPackagesActivated(false);
      return 0;
    }
'''
if a.count(old) != 1:
    raise SystemExit('Refusing unexpected flattened apexd_main.cpp branch')
a = a.replace(old, '', 1)
old = '  if (!android::sysprop::ApexProperties::updatable().value_or(false)) {'
if a.count(old) != 1:
    raise SystemExit('Refusing unexpected early apexd subcommand context')
a = a.replace(old,
              '  if (has_subcommand && !android::sysprop::ApexProperties::updatable().value_or(false)) {',
              1)
old = '''  if (has_subcommand) {
    return HandleSubcommand(argc, argv);
  }

  auto session_manager ='''
new = '''  if (has_subcommand) {
    return HandleSubcommand(argc, argv);
  }

  if (!android::sysprop::ApexProperties::updatable().value_or(false)) {
    // Keep IApexService registered for Android 16 KeyMint module measurement.
    // No OnStart(): it only selects packaged APEXes and may access loop/DM.
    android::apex::binder::CreateAndRegisterService();
    android::apex::binder::StartThreadPool();
    if (booting) android::apex::OnAllPackagesActivated(false);
    android::apex::binder::JoinThreadPool();
    return 1;
  }

  auto session_manager ='''
if a.count(old) != 1:
    raise SystemExit('Refusing unexpected apexd service startup context')
a = a.replace(old, new, 1)

old = '#include "apex_file_repository.h"\n'
new = old + '#include "apex_manifest.h"\n#include "apexd_utils.h"\n'
if b.count(old) != 1:
    raise SystemExit('Refusing unexpected apexservice includes')
b = b.replace(old, new, 1)
old = 'static ApexInfo GetApexInfo(const ApexFile& package) {'
new = '''static std::vector<ApexInfo> GetFlattenedApexInfos() {
  std::vector<ApexInfo> infos;
  auto dirs = GetSubdirs(kApexRoot);
  if (!dirs.ok()) {
    LOG(ERROR) << "Cannot scan flattened APEXes: " << dirs.error();
    return infos;
  }
  std::sort(dirs->begin(), dirs->end());
  for (const auto& path : *dirs) {
    auto manifest = ReadManifest(path + "/" + kManifestFilenamePb);
    if (!manifest.ok()) continue;  // E.g. /apex/sharedlibs.
    const auto vendor_path = std::string(kApexPackageVendorDir) + "/" + manifest->name();
    const bool vendor = access(vendor_path.c_str(), F_OK) == 0;
    ApexInfo info;
    info.moduleName = manifest->name();
    info.modulePath = path;
    info.preinstalledModulePath = vendor
            ? vendor_path
            : std::string(kApexPackageSystemDir) + "/" + manifest->name();
    info.versionCode = manifest->version();
    info.versionName = manifest->versionname();
    info.isFactory = true;
    info.isActive = true;
    info.partition = Cast(vendor ? ApexPartition::Vendor : ApexPartition::System);
    infos.push_back(std::move(info));
  }
  return infos;
}

static ApexInfo GetApexInfo(const ApexFile& package) {'''
if b.count(old) != 1:
    raise SystemExit('Refusing unexpected ApexService conversion context')
b = b.replace(old, new, 1)
old = '''  auto packages = ::android::apex::GetActivePackages();
  for (const auto& package : packages) {'''
new = '''  if (!android::base::GetBoolProperty("ro.apex.updatable", false)) {
    *aidl_return = GetFlattenedApexInfos();
    return BinderStatus::ok();
  }

  auto packages = ::android::apex::GetActivePackages();
  for (const auto& package : packages) {'''
if b.count(old) != 1:
    raise SystemExit('Refusing unexpected getActivePackages context')
b = b.replace(old, new, 1)
old = '''  const auto& active = ::android::apex::GetActivePackages();
  const auto& factory = ::android::apex::GetFactoryPackages();'''
new = '''  if (!android::base::GetBoolProperty("ro.apex.updatable", false)) {
    *aidl_return = GetFlattenedApexInfos();
    return BinderStatus::ok();
  }

  const auto& active = ::android::apex::GetActivePackages();
  const auto& factory = ::android::apex::GetFactoryPackages();'''
if b.count(old) != 1:
    raise SystemExit('Refusing unexpected getAllPackages context')
b = b.replace(old, new, 1)
main.write_text(a)
service.write_text(b)
PY
runuser -u aosp -- git -C /work/aosp/source/system/apex diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 apexd
' > /work/aosp/apexd-flat-service-build.log 2>&1
echo 'Flattened apexd service compiled; no CT updated.'
