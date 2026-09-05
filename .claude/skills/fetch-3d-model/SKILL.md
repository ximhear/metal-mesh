---
name: fetch-3d-model
description: 무료(CC0/CC-BY/공개 연구용) 사이트에서 3D 모델 파일을 내려받아 이 프로젝트의 샘플 폴더에 넣고 라이선스를 기록한다. "모델 가져와", "샘플 3D 파일 추가", "bunny 다운로드", "Poly Haven에서 ~ 받아와" 같은 요청에 사용.
---

# fetch-3d-model

이 앱이 바로 읽을 수 있는 포맷: **OBJ, PLY, STL, USD/USDA/USDC/USDZ** (Model I/O), **GLB / glTF** (자체 로더, 삼각형 메시·baseColor만.
Draco 압축·스키닝·애니메이션 미지원). 현재 목록은 `Import/ModelLoader.swift`의 `supportedExtensions`로 확인한다.

저장 위치: `MetalMesh/Resources/Samples/<모델이름>/` (파일 + `LICENSE.txt`) — 저장소 루트 기준
기록 위치: `MetalMesh/Resources/Samples/MODELS.md` (이름, 출처 URL, 라이선스, 포맷, 정점 수 한 줄씩 append)

## 1. 소스 우선순위 (2026-09 동작 확인. Sketchfab·Poly Pizza는 API 키 필요)

| 우선 | 소스 | 포맷 | 라이선스 | 용도 |
|---|---|---|---|---|
| 1 | Poly Haven `https://api.polyhaven.com` | **usdc**, gltf, fbx, blend + 텍스처 | CC0 | 텍스처 있는 실사 모델 |
| 2 | alecjacobson/common-3d-test-models (GitHub) | **obj** | 모델별 상이(README 확인) | bunny, armadillo, teapot 등 표준 테스트 메시 |
| 3 | Stanford 3D Scanning Repository `http://graphics.stanford.edu/pub/3Dscanrep/` | **ply** (tar.gz) | 연구·비상업, 출처 표기 | 고해상도 스캔(bunny 7만, dragon 87만 삼각형) — 메시렛 부하 테스트 |
| 4 | Sketchfab Data API v3 `https://api.sketchfab.com/v3` | **usdz**, glb, gltf(zip), source | 모델별 CC (검색 시 `downloadable=true`) | 가장 넓은 선택지. 다운로드에 키 필요 — `.env.local`의 `SKETCHFAB_API_KEY` |
| 5 | Poly Pizza `https://api.poly.pizza/v1.1` | **glb** | CC0 / CC-BY 3.0 (모델별) | 로우폴리 게임 스타일 모델. 키 필요 — `.env.local`의 `POLY_PIZZA_API_KEY` |
| 6 | KhronosGroup/glTF-Sample-Assets (GitHub) | glb/gltf | 모델별(대부분 CC) | 렌더러 호환성 테스트 |

GLB 소스(5, 6)는 그대로 받아 쓴다. 단 Draco 압축(`KHR_draco_mesh_compression`) 파일은 로더가 거부하므로 프로브로 확인한다.
Smithsonian은 브라우저 세션이 필요하므로 이 스킬에서는 쓰지 않는다.
사용자가 특정 사이트를 지정하면 그 지시가 우선한다.

## 2. Poly Haven 절차

```bash
# 목록/검색 (t=models, 필요시 c=<category>)
curl -s "https://api.polyhaven.com/assets?t=models" | python3 -c '
import sys,json; d=json.load(sys.stdin)
for k,v in d.items():
    print(k, "|", v["name"], "|", ",".join(v["categories"]))' | grep -i "<키워드>"

# 파일 URL 조회 → usd 1k 항목의 url (usdc) 과 include(텍스처) 를 받는다
curl -s "https://api.polyhaven.com/files/<asset_id>" > /tmp/ph.json
python3 - <<'EOF'
import json,subprocess,os
d=json.load(open("/tmp/ph.json"))
res="1k"                      # 1k/2k/4k — 기본 1k, 사용자가 요구하면 변경
u=d["usd"][res]["usd"]
out=f"MetalMesh/Resources/Samples/<asset_id>"
os.makedirs(out+"/textures",exist_ok=True)
subprocess.run(["curl","-sL","-o",f"{out}/{os.path.basename(u['url'])}",u["url"]],check=True)
for rel,f in u["include"].items():
    subprocess.run(["curl","-sL","-o",f"{out}/{rel}",f["url"]],check=True)
EOF
```

- 라이선스는 항상 CC0 → `LICENSE.txt`에 "CC0 1.0 — https://polyhaven.com/a/<asset_id>" 기록.
- `usd` 키가 없는 에셋이면 `gltf`로 받은 뒤 5절 변환. 변환 수단이 없으면 사용자에게 알리고 다른 모델 제안.

## 3. GitHub 테스트 메시 절차 (common-3d-test-models)

```bash
BASE=https://raw.githubusercontent.com/alecjacobson/common-3d-test-models/master
curl -sL "$BASE/README.md" | grep -i "<이름>"          # 파일명과 라이선스 열 확인
curl -sL -o MetalMesh/Resources/Samples/<이름>/<이름>.obj "$BASE/data/<파일명>.obj"
```

주요 파일명: `stanford-bunny.obj`, `armadillo.obj`, `teapot.obj`, `cow.obj`, `spot.obj`, `nefertiti.obj`, `xyzrgb_dragon.obj`.
README의 라이선스 열을 그대로 `LICENSE.txt`에 옮긴다. 비상업 조건이 붙은 모델은 MODELS.md에 명시.

## 4. Stanford 스캔 절차

```bash
curl -sL -o /tmp/bunny.tar.gz http://graphics.stanford.edu/pub/3Dscanrep/bunny.tar.gz
tar -xzf /tmp/bunny.tar.gz -C /tmp
# reconstruction/bun_zipper.ply 가 전체 메시. 해상도 축소판: bun_zipper_res2/3/4.ply
cp /tmp/bunny/reconstruction/bun_zipper.ply MetalMesh/Resources/Samples/stanford-bunny-ply/
```

다른 모델: `dragon_recon.tar.gz`, `happy_recon.tar.gz`, `armadillo.tar.gz`, `lucy.tar.gz`(1.4억 삼각형, 매우 큼 — 사용자 요청 없으면 받지 않음).
라이선스: 저장소 안내문대로 "Stanford Computer Graphics Laboratory 출처 표기, 비상업 용도".

## 4a. Sketchfab 절차 (API 키 필요)

키는 `.env.local`의 `SKETCHFAB_API_KEY`. 검색은 키 없이 되지만 다운로드 URL 발급에는 키가 필요하다.
발급 URL은 **300초 후 만료**되므로 발급 직후 바로 받는다. 키 값을 출력하지 말 것.

```bash
set -a; source .env.local; set +a
# 1) 검색: downloadable=true 필수. 결과의 license.label, user.username, faceCount 확인
#    `license=` 필터는 uid 값이 아니라 특정 선택지만 받으므로 쓰지 말고 결과의 license.label로 골라낸다
curl -s "https://api.sketchfab.com/v3/search?type=models&downloadable=true&q=<키워드>&count=10&sort_by=-likeCount" > /tmp/sf.json
python3 -c '
import json; d=json.load(open("/tmp/sf.json"))
for m in d["results"]:
    print(m["uid"], "|", m["name"], "|", m["license"]["label"], "|", m["user"]["username"], "|", m.get("faceCount"))'

# 2) 다운로드 URL 발급 → usdz 우선, 없으면 glb. (변수명 UID는 zsh 예약어이므로 MID 사용)
MID=<uid>
curl -s -H "Authorization: Token $SKETCHFAB_API_KEY" "https://api.sketchfab.com/v3/models/$MID/download" > /tmp/sfdl.json
URL=$(python3 -c 'import json; d=json.load(open("/tmp/sfdl.json")); print((d.get("usdz") or d["glb"])["url"])')
mkdir -p MetalMesh/Resources/Samples/<이름> && curl -sL -o MetalMesh/Resources/Samples/<이름>/<이름>.usdz "$URL"
```

- `usdz` 키는 압축된 .usdz 단일 파일. `gltf` 키는 zip이라 풀어야 함. `source`는 원본(대용량, 받지 않음).
- 라이선스: `license.label`(예: CC Attribution)을 그대로 쓰고 **작성자 username과 `https://sketchfab.com/3d-models/<slug>-<uid>` 링크를 `LICENSE.txt`에 기록**. CC-BY 계열은 표기가 의무.
- `faceCount`가 200만 초과면 사용자 확인 후 받는다.
- 401/403이면 키 문제 → 사용자에게 알림. 재시도 반복 금지.

## 4b. Poly Pizza 절차 (API 키 필요)

키는 프로젝트 루트 `.env.local`의 `POLY_PIZZA_API_KEY`에 있다. 키 값을 대화나 커밋 파일에 옮겨 적지 말고 항상 파일에서 읽는다.
`.env.local`이 없으면 사용자에게 키를 요청한다 (https://poly.pizza/settings/api 에서 무료 발급).

```bash
set -a; source .env.local; set +a
# 검색: /search/<키워드>?Limit=N  (응답: total, results[])
curl -s -H "x-auth-token: $POLY_PIZZA_API_KEY" \
  "https://api.poly.pizza/v1.1/search/<키워드>?Limit=10" > /tmp/pp.json
python3 -c '
import json; d=json.load(open("/tmp/pp.json"))
for m in d["results"]:
    print(m["ID"], "|", m["Title"], "|", m["Licence"], "|", m["Creator"]["Username"], "|", m["Download"])'
# 다운로드 (Download 필드는 static.poly.pizza/*.glb 직접 링크, 키 불필요)
mkdir -p MetalMesh/Resources/Samples/<이름> && curl -sL -o MetalMesh/Resources/Samples/<이름>/<이름>.glb "<Download URL>"
```

- 라이선스는 결과의 `Licence` 필드를 그대로 기록. **CC-BY 3.0이면 `LICENSE.txt`에 Creator.Username을 반드시 표기**.
- 응답이 401이면 키 만료/오타 → 사용자에게 알림. 재시도 반복 금지.
- 받은 GLB는 그대로 등록. 프로브(`scripts/probe-model.swift`는 Model I/O 전용이므로 GLB는 앱 테스트 `GLBLoaderTests`나 임포트로 확인).

## 5. glTF/GLB → USD 변환 (이제 선택 사항)

앱이 GLB를 직접 읽으므로 보통 변환이 필요 없다. Draco 압축 GLB처럼 로더가 거부하는 파일만,
이 세션에 Blender MCP(`mcp__blender__*`)가 연결돼 있을 때 `execute_blender_code`로
`bpy.ops.import_scene.gltf(filepath=...)` → `bpy.ops.wm.usd_export(filepath=..., export_textures=True)` 순서로 변환한다.
Blender가 없으면 변환하지 않고 사용자에게 알린다. 변환 코드를 추측으로 짜지 말 것.

## 6. 받은 뒤 반드시 할 것

1. 파일 크기와 확장자 확인 (`ls -la`, `file`). 0바이트/HTML 응답이면 실패로 보고.
2. 정점·삼각형 수 확인: 모든 포맷 공통으로 Model I/O 프로브 스크립트를 쓴다 (`scripts/probe-model.swift`, `swiftc -O`로 컴파일 후 파일 경로들을 인자로). 로드 실패 시 앱에서도 실패하므로 받지 않는다.
3. `MetalMesh/Resources/Samples/MODELS.md`에 한 줄 append.
4. Xcode 프로젝트가 XcodeGen이면 `Resources/` 폴더 참조라 재생성 불필요. 아니면 `xcodegen generate` 안내.
5. 사용자에게 받은 파일 경로, 크기, 삼각형 수, 라이선스를 짧게 보고.

## 7. 하지 말 것

- 라이선스 불명확한 사이트(개인 블로그, 포럼 첨부) 사용 금지.
- Sketchfab·Poly Pizza 외에 로그인/API 키가 필요한 사이트에 사용자 계정 정보 입력 금지. 키 값은 절대 출력·커밋하지 않음.
- 500MB 이상 파일은 사용자가 명시하지 않으면 받지 않음.
