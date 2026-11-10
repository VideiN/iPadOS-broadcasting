#!/bin/bash
# 로컬(맥)에서 빌드한 앱을 TestFlight에 올린다 (2026-11-10).
# 빌드를 마저 하고 가짜 서명 IPA로 묶어 draft Release에 올린 뒤, 서명·업로드 워크플로(testflight-local.yml)를 main에서 실행한다.
# 서명 비밀값은 GitHub의 testflight 환경에만 있고 이 스크립트는 쓰지 않는다. 필요한 것은 gh 로그인뿐
#
# 사용법: upload-local-build.sh [빌드 폴더]   (기본 build_ios-iphoneos, README의 "빌드 (macOS)"로 설정해 둔 것)
# 작업 트리가 깨끗하고 HEAD가 원격에 올라가 있어야 한다 (앱의 빌드 정보에 들어가는 커밋이 실제로 있게)

set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
build_dir=${1:-$root_dir/build_ios-iphoneos}
cd "$root_dir"

if [ -n "$(git status --porcelain)" ]; then
  echo "error: the working tree has changes; commit them first" >&2
  exit 1
fi
git fetch -q origin
commit=$(git rev-parse HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
if [ -z "$(git branch -r --contains "$commit")" ]; then
  echo "error: $branch ($(git rev-parse --short HEAD)) is not pushed" >&2
  exit 1
fi

# 다시 설정해서 빌드 번호를 지금 시각으로 (app/CMakeLists.txt). 같은 번호는 App Store Connect가 받지 않는다
if ! log=$(cmake "$build_dir" 2>&1); then
  echo "$log" >&2
  exit 1
fi
cmake --build "$build_dir" --parallel
app=$(ls -d "$build_dir"/app/*.app)
name=$(basename "$app" .app)
if [ "$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$app/Info.plist")" != iphoneos ]; then
  echo "error: $build_dir is not a device (iphoneos) build" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tag="local-${commit::7}-$(date -u +%Y%m%d%H%M%S)"
ipa="$work/$name-$tag.ipa"
mkdir -p "$work/ipa/Payload"
cp -R "$app" "$work/ipa/Payload/"
(cd "$work/ipa" && zip -qry "$ipa" Payload)
sha256=$(shasum -a 256 "$ipa" | awk '{ print $1 }')

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh release create "$tag" "$ipa" --repo "$repo" --draft --target "$commit" \
  --title "$tag" --notes "로컬 빌드 $branch ${commit::7}. testflight-local.yml이 올린 뒤 지운다"
gh workflow run testflight-local.yml --repo "$repo" --ref main \
  -f tag="$tag" -f sha256="$sha256" -f branch="$branch" -f commit="$commit"
echo "uploaded $tag; started testflight-local.yml"
echo "see: gh run list --repo $repo --workflow testflight-local.yml --limit 1"
