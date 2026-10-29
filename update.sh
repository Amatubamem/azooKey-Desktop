#!/bin/bash
set -xe -o pipefail

IGNORE_LINT=false
DRY_RUN=false
NO_PKILL=false
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_APP="/Library/Input Methods/azooKeyMac.app"
BUILT_APP="${REPO_ROOT}/build/DerivedData/Build/Products/Release/azooKeyMac.app"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ignore-lint) IGNORE_LINT=true ;;
        --dry-run) DRY_RUN=true ;;
        --no-pkill) NO_PKILL=true ;;
        *) echo "Unknown parameter passed: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ ! -d "$INSTALLED_APP" ]; then
    echo "入力メソッドが未インストールです。初回は ./install.sh を実行してください。" >&2
    exit 1
fi

cd "$REPO_ROOT"
if [ "$IGNORE_LINT" = false ]; then
    if command -v swiftlint &> /dev/null; then
        swiftlint --fix --format
        swiftlint --quiet --strict
    else
        echo "SwiftLintが見つかりません。--ignore-lintを指定するか、brew install swiftlintで導入してください。" >&2
        exit 1
    fi
fi

# 中間生成物を再利用して、変更した部分だけを再ビルドする。
if command -v xcpretty &> /dev/null; then
    xcodebuild -project azooKeyMac.xcodeproj -scheme azooKeyMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "${REPO_ROOT}/build/DerivedData" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARCHS=arm64 build | xcpretty
else
    xcodebuild -project azooKeyMac.xcodeproj -scheme azooKeyMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "${REPO_ROOT}/build/DerivedData" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARCHS=arm64 build
fi

# バンドルIDが異なるアプリは、登録済みの入力メソッドとして更新しない。
installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INSTALLED_APP}/Contents/Info.plist")
built_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${BUILT_APP}/Contents/Info.plist")
if [ "$installed_id" != "$built_id" ]; then
    echo "バンドルIDが異なるため更新を中止しました: ${installed_id} != ${built_id}" >&2
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would execute the following commands:"
    echo "  sudo ${REPO_ROOT}/Tools/remove_converter_server_launch_agent.sh"
    echo "  sudo rsync -rlpt --delete '${BUILT_APP}/' '${INSTALLED_APP}/'"
    if [ "$NO_PKILL" = false ]; then
        echo "  pkill azooKeyMac || true"
    fi
    echo "  swift '${REPO_ROOT}/Tools/register_input_source.swift' '${INSTALLED_APP}'"
    echo "Build completed successfully. Use without --dry-run to actually update."
else
    sudo "${REPO_ROOT}/Tools/remove_converter_server_launch_agent.sh"
    # 入力ソースの登録を維持するため、.appを削除せずに更新する。
    sudo rsync -rlpt --delete "${BUILT_APP}/" "${INSTALLED_APP}/"
    if [ "$NO_PKILL" = false ]; then
        pkill azooKeyMac || true
    fi
    swift "${REPO_ROOT}/Tools/register_input_source.swift" "$INSTALLED_APP"
fi
