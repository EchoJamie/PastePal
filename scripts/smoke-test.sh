#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${PASTEPAL_APP_PATH:-}" ]]; then
  app_path="$PASTEPAL_APP_PATH"
else
  ./scripts/build-app.sh preview release
  app_path="$PWD/build/PastePal Preview.app"
fi
build_flavor="$(plutil -extract PastePalBuildFlavor raw "$app_path/Contents/Info.plist" 2>/dev/null || echo release)"
build_configuration="$(plutil -extract PastePalBuildConfiguration raw "$app_path/Contents/Info.plist" 2>/dev/null || echo release)"
if [[ "$build_flavor" == preview ]]; then
  display_name="PastePal Preview"; chinese_name="$display_name"
else
  display_name="PastePal"; chinese_name="贴伴"
fi
[[ "$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist")" == "$display_name" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == "local.jamie.PastePal" ]]
[[ "$(plutil -extract CFBundleIconFile raw "$app_path/Contents/Info.plist")" == "AppIcon" ]]
[[ -s "$app_path/Contents/Resources/AppIcon.icns" ]]
[[ "$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Resources/en.lproj/InfoPlist.strings")" == "$display_name" ]]
[[ "$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Resources/zh-Hans.lproj/InfoPlist.strings")" == "$chinese_name" ]]
[[ "$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Resources/zh-Hant.lproj/InfoPlist.strings")" == "$chinese_name" ]]
[[ -d "$app_path/Contents/Resources/PastePal_PastePal.bundle" ]]
[[ -d "$app_path/Contents/Resources/PastePal_PastePalLocalization.bundle" ]]
[[ -d "$app_path/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle" ]]
[[ ! -e "$app_path/PastePal_PastePal.bundle" ]]
[[ ! -e "$app_path/KeyboardShortcuts_KeyboardShortcuts.bundle" ]]
[[ ! -e "$app_path/Contents/Resources/MacClipboard_MacClipboard.bundle" ]]
[[ ! -e "$PWD/build/SidePocket.app" && ! -L "$PWD/build/SidePocket.app" ]]
[[ ! -e "$PWD/build/本地剪贴板.app" && ! -L "$PWD/build/本地剪贴板.app" ]]
mkdir -p build/validation
run_dir="$(mktemp -d "$PWD/build/validation/smoke.XXXXXX")"
standalone_app="$run_dir/$(basename "$app_path")"
ditto "$app_path" "$standalone_app"
codesign --verify --deep --strict "$standalone_app"
bin_dir="${PASTEPAL_BIN_DIR:-$(./scripts/swift-env.sh build -c "$build_configuration" --show-bin-path)}"
resource_bundles=("PastePal_PastePal.bundle" "PastePal_PastePalLocalization.bundle")
restore_fallback() {
  local bundle_name
  for bundle_name in "${resource_bundles[@]}"; do
    if [[ -e "$bin_dir/.$bundle_name.smoke-hidden" ]]; then
      mv "$bin_dir/.$bundle_name.smoke-hidden" "$bin_dir/$bundle_name"
    fi
  done
}
trap restore_fallback EXIT
for bundle_name in "${resource_bundles[@]}"; do
  [[ ! -e "$bin_dir/.$bundle_name.smoke-hidden" ]] || { printf '资源检查目录已被占用：%s\n' "$bundle_name" >&2; trap - EXIT; exit 1; }
done
for bundle_name in "${resource_bundles[@]}"; do
  mv "$bin_dir/$bundle_name" "$bin_dir/.$bundle_name.smoke-hidden"
done
PASTEPAL_SMOKE_DIR="$run_dir" "$standalone_app/Contents/MacOS/PastePal" --smoke-test --exit-after-smoke -appLanguage zh-Hans
restore_fallback
trap - EXIT
python3 - "$run_dir" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1])
result=json.loads((root/'native-smoke.json').read_text())
assert result['translationResourcesLoaded']
assert result['localizedAppName'] in {'贴伴', 'PastePal', 'PastePal Preview'}
assert result['mainMenuUsesLocalizedAppName'] and result['settingsTitleUsesLocalizedAppName'] and result['statusItemUsesLocalizedAppName']
assert result['statusItemImageIsTemplate'] and result['statusItemImageSizeIs18'] and result['statusItemImageUsesPastePalResource']
assert result['bundleAppIconLoaded']
assert result['nativeWindowRendered'] and result['compactWidthRendered'] and result['searchStateRendered'] and result['emptyStateRendered'] and result['sampleRecords'] == 10
assert result['preferredPanelHeightIs356'] and result['cardsAreLargerWithOriginalAspectRatio']
assert result['cardsUseRecoveredBottomSpace'] and result['hintSharesTopRowWithoutOverlap']
assert result['panelUsesTargetScreenRealBottomAndFullWidth'] and result['nativeMouseRoutingValidated']
assert result['longSingleLineTextRendered'] and result['unknownSourceRendered']
assert result['idleToolbarCentered'] and result['compactToolbarCentered']
assert result['searchEditingToolbarCentered'] and result['searchCompletedToolbarCentered'] and result['cancelledToolbarCentered']
assert result['noGroupToolbarHasSearchAndCreate'] and result['customGroupToolbarRendered'] and result['selectedGroupRendered']
assert result['groupSearchScopeRendered'] and result['searchScopeRemovalRendered']
assert result['groupSearchCancelRestored'] and result['groupPickerRendered'] and result['customGroupCount'] == 10
assert result['contextualGroupDeleteRendered'] and result['groupInlineManagementAvailable'] and result['groupEditorRendered']
assert result['fileCardRendered'] and result['colorCardRendered'] and result['animatedGIFCardRendered'] and result['multiItemFileCardRendered']
assert result['linkMetadataCardRendered'] and result['sourceAndSiteSeparated'] and result['cachedSourceIconRendered']
assert result['inferredSourceTooltipRendered']
assert result['panelUsesVisualEffectBackground'] and result['backgroundMaterialIsPopover'] and result['backgroundKeepsFullOpacity']
assert result['backgroundAndContentAreSeparateSiblings']
assert result['backgroundBlendingIsBehindWindow'] and result['backgroundStateIsActive']
assert result['windowUsesClearBackground'] and result['windowKeepsNativeShadow']
assert result['panelClipsContinuousRoundedCorners'] and result['panelRoundsOnlyTopCorners'] and result['panelHasNoRectangularLayerBorder']
assert result['cardVisualEffectSubviewCount'] == 0
assert result['panelPopupButtonCount'] == 0 and result['panelSegmentedControlCount'] == 0 and result['panelSettingsButtonCount'] == 0
assert {'纯文本使用所选', '将所选加入分组…', '永久删除所选（Delete）', '新建分组…', '管理分组', '设置…'} <= set(result['statusMenuItems'])
assert result['statusMenuAutomaticEnablingDisabled']
assert result['plainActionDisabledForImage'] and result['statusActionsEnabledInCardState'] and result['statusActionsDisabledWithoutPanel']
assert result['noSeparateCopyOnlyMenu'] and result['plainShortcutIsOptionReturn']
assert result['addToGroupShortcutIsCommandG'] and result['groupManagementMenuRendered']
assert result['settingsGeneralRendered'] and result['settingsShortcutsRendered']
assert result['settingsRetentionRendered'] and result['settingsPrivacyRendered']
assert result['settingsSidebarIconsAdaptive'] and result['settingsDefaultWidthExpanded']
for name in ['native-panel-no-groups.png','native-panel-groups.png','native-panel-group-selected.png','native-panel-groups-compact.png','native-panel-group-search.png','native-panel-search-all.png','native-panel-group-search-completed.png','native-panel-empty.png','native-panel-group-search-cancelled.png','native-group-picker.png','native-group-editor.png','native-group-label-editing.png','native-group-delete-confirmation.png','native-panel-dark.png','native-settings.png','native-settings-general-dark.png','native-settings-shortcuts-dark.png','native-settings-history-count-dark.png','native-settings-history-dark.png','native-settings-privacy-dark.png']:
    assert (root/name).stat().st_size > 1000
print('原生冒烟检查完成：'+str(root))
print('本检查使用隔离样例历史，不启动通用剪贴板监听，也不验证跨应用粘贴。')
PY
