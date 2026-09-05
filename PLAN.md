# MetalMesh — Metal 3 메시 셰이더 3D 뷰어 구현 계획

## 1. 목표

- Xcode 기반 SwiftUI 앱 (iOS + macOS 멀티플랫폼)
- 3D 모델 파일을 **Metal 3 메시 셰이더 파이프라인 (object → mesh → fragment)** 으로 렌더링
- 첫 화면: 계속 추가되는 모델 리스트 → 항목 탭 → 해당 모델을 보여주는 뷰어 화면

## 2. 확정 사항 / 가정

| 항목 | 결정 | 이유 |
|---|---|---|
| 배포 타깃 | iOS 17 / macOS 14 | Metal 3 + `@Observable`, NavigationStack 안정 버전 |
| GPU 요구 | `device.supportsFamily(.apple7)` 이상 (A14/M1+). 미지원 기기는 안내 화면 | 메시 셰이더는 Apple7 패밀리부터. 실제 최소 기기는 Feature Set Table로 런타임 확인 |
| 프로젝트 생성 | **XcodeGen** (`project.yml` → `.xcodeproj`) | 로컬에 설치됨. pbxproj를 손으로 관리하지 않고 CLI에서 재생성 가능 |
| UI | SwiftUI + `NavigationStack`, MTKView는 `ViewRepresentable`로 래핑 | |
| 1차 지원 포맷 | **OBJ, PLY, STL, USD/USDA/USDC/USDZ** (Model I/O `MDLAsset`) | 별도 파서 없이 정점/인덱스 추출 가능. `fetch-3d-model` 스킬의 포맷 목록과 동일 |
| 2차 포맷 | **GLB / glTF** (자체 최소 파서, 완료) | Poly Pizza·Khronos 샘플이 전부 GLB. 삼각형 메시만 지원(스키닝/애니메이션/Draco 제외), 텍스처는 baseColor만 |
| 메시렛 한계 | 정점 ≤ 64, 삼각형 ≤ 126 (Metal 최대치는 256 / 512) | 캐시 효율과 스레드그룹 크기 균형. 상수로 조절 가능하게 |
| 개발 검증 기기 | 이 맥(M2 Pro) | 시뮬레이터는 메시 셰이더 미지원 → macOS 타깃으로 먼저 개발 |

## 3. 앱 구조

```
metal-mesh/                          # 저장소 루트
├── project.yml                      # XcodeGen 정의 (단일 멀티플랫폼 타깃, supportedDestinations)
├── .env.local                       # API 키 (gitignore)
├── .claude/skills/fetch-3d-model/   # 모델 수집 스킬
├── Tests/                           # 단위 테스트 (Swift Testing)
└── MetalMesh/                       # 앱 소스 루트
├── MetalMesh-Bridging-Header.h      # ShaderTypes.h를 Swift에 노출 (앱·테스트 타깃 공용)
├── App/
│   ├── MetalMeshApp.swift           # @main
│   ├── RootView.swift               # 지원 여부에 따라 NavigationStack / 안내 화면 분기
│   ├── DeviceCapability.swift       # 메시 셰이더 지원 여부 검사 (metal3 + apple7|mac2)
│   └── UnsupportedDeviceView.swift
├── Library/                         # 1번 화면: 모델 리스트 (완료)
│   ├── ModelEntry.swift             # id, 이름, source(bundled|imported 상대경로), 통계, licenseText
│   ├── ModelLibrary.swift           # @Observable 저장소, Documents/library.json + Documents/Models/<uuid>/
│   ├── ModelListView.swift          # List + fileImporter + dropDestination + 삭제
│   └── ModelRowView.swift
├── Viewer/                          # 2번 화면: 렌더링 (완료)
│   ├── ModelViewerView.swift        # 로드 상태, MetalView, 툴바, 통계 바, 정보 시트
│   ├── MetalView.swift              # InteractiveMTKView(제스처) + NSView/UIViewRepresentable 브리지
│   └── OrbitCamera.swift            # 회전/줌/팬, 경계 구 자동 프레이밍
├── Rendering/                       # (완료)
│   ├── Renderer.swift               # MTKViewDelegate, 파이프라인 생성, 트리플 버퍼링, drawMeshThreadgroups, 통계
│   ├── GPUMesh.swift                # 메시렛 버퍼 세트 (MTLBuffer 묶음)
│   ├── RenderSettings.swift         # DebugMode, RenderSettings, RenderStats
│   ├── Math.swift                   # 투영/lookAt/프러스텀 평면 추출
│   └── Shaders/
│       ├── ShaderTypes.h            # Swift/MSL 공유 (Vertex, Meshlet, Uniforms, MeshletPayload, 버퍼 인덱스)
│       └── MeshShaders.metal        # objectMain / meshMain / fragmentMain
├── Import/                          # (완료)
│   ├── ModelIOQueue.swift           # Model I/O 직렬화 액터 (libusd 동시 로드 크래시 회피)
│   ├── ModelProbe.swift             # 정점/삼각형 수만 세는 경량 로더
│   ├── ModelLoader.swift            # MDLAsset → MeshData(Vertex[], UInt32[], bounds)
│   └── MeshletBuilder.swift         # MeshData → MeshletMesh(meshlets, meshletVertices, meshletTriangles)
└── Resources/
    └── Samples/                     # 번들 샘플 모델(폴더 참조) + MODELS.md
```

테스트 파일(`Tests/`): DeviceCapabilityTests(완료), MeshletBuilderTests, ModelLoaderTests

## 4. 데이터 흐름

```
파일 URL
  → ModelLoader (Model I/O)            : 정점 배열 + 인덱스 배열 (단일 포맷으로 정규화)
  → MeshletBuilder (CPU, 백그라운드)     : Meshlet[] { vertexOffset, vertexCount,
                                                       triangleOffset, triangleCount,
                                                       boundsCenter, boundsRadius,
                                                       coneAxis, coneCutoff }
                                          + meshletVertices: uint32[]  (전역 정점 인덱스)
                                          + meshletTriangles: uint8[]  (메시렛 로컬 인덱스, 3개씩)
  → GPUMesh                             : MTLBuffer 5개 (vertices, meshlets, meshletVertices,
                                                        meshletTriangles, uniforms)
  → Renderer.draw                       : drawMeshThreadgroups(
                                            threadgroupsPerGrid: ceil(meshletCount / 32),
                                            threadsPerObjectThreadgroup: 32,
                                            threadsPerMeshThreadgroup: 128)
```

### 셰이더 단계

- **Object shader**: 스레드 1개 = 메시렛 1개. 프러스텀 컬링(경계 구) + 백페이스 콘 컬링 →
  살아남은 메시렛 인덱스를 `object_data` 페이로드에 압축 저장 → `set_threadgroups_per_grid(alive, 1, 1)`
- **Mesh shader**: 스레드그룹 1개 = 메시렛 1개. 스레드가 정점 변환(`set_vertex`), 삼각형 인덱스 기록(`set_index`),
  프리미티브 데이터(메시렛 ID → 디버그 색)(`set_primitive`), `set_primitive_count`
- **Fragment**: 간단한 Blinn-Phong 또는 노멀 기반 셰이딩. 디버그 모드에서 메시렛별 색상

## 5. 단계별 진행

### Phase 0 — 프로젝트 골격 ✅ (2026-09-05 완료)
- [x] `git init`, `.gitignore`
- [x] `project.yml` 작성 → `xcodegen generate` → `xcodebuild` 빌드 통과 (macOS, iOS 기기, iOS 시뮬레이터)
- [x] `DeviceCapability`: 메시 셰이더 미지원 시 안내 뷰
- [x] 단위 테스트 타깃 (Swift Testing) — macOS/시뮬레이터에서 통과
- **완료 기준 충족**: macOS에서 앱 실행 시 "Models" 창 표시
- 메모: 멀티플랫폼 테스트 타깃은 `TEST_HOST[sdk=macosx*]`를 따로 지정해야 함(project.yml 참고)

빌드/테스트 명령:
```bash
xcodegen generate
xcodebuild -project MetalMesh.xcodeproj -scheme MetalMesh -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

### Phase 1 — 모델 리스트 화면 ✅ (2026-09-05 완료)
- [x] `ModelEntry`, `ModelLibrary` (Documents/library.json + Documents/Models/<uuid>/, 삭제는 임포트 항목만)
- [x] `ModelListView`: `.fileImporter`(다중 선택), `dropDestination`(macOS/iOS 공통), 번들 샘플 자동 등록, 삭제(스와이프/컨텍스트 메뉴)
- [x] `ModelProbe`: Model I/O로 정점/삼각형 수 계산 (직렬 액터)
- [x] 행 탭 → `ModelViewerView(entry:)` 자리 화면 (파일 정보 + LICENSE 표시)
- [x] 테스트 4개: 샘플 중복 등록 없음, 임포트 영속·삭제, 미지원 확장자 거부, 샘플 삭제 불가
- **완료 기준 충족**: macOS 실행 시 샘플 6개가 통계와 함께 표시(library.json 확인)
- 메모: **libusd_ms는 USD 파일을 여러 스레드에서 동시에 처음 열면 크래시**(Sdf_GetExtension 널 역참조).
  Model I/O 호출은 반드시 `ModelProbe.serialQueue`처럼 직렬화할 것. Phase 2 로더도 같은 규칙 적용.

### Phase 2 — 로딩 + 메시렛 빌더 (CPU) ✅ (2026-09-05 완료)
- [x] `ShaderTypes.h`: Vertex(48B) / Meshlet(64B) 레이아웃 + 한계 상수. 브리징 헤더로 Swift·테스트·MSL 공유
- [x] `ModelIOQueue`: 모든 Model I/O 호출을 직렬화하는 액터 (프로브·로더 공용)
- [x] `ModelLoader`: preserveTopology=false로 삼각형화, 노드 변환 적용, 노멀 없으면 생성, Vertex 레이아웃으로 정규화
- [x] `MeshletBuilder`: 인덱스 순서 그리디 분할, AABB 중심 경계 구, meshoptimizer 규약 노멀 콘(cutoff 1 = 컬링 불가)
- [x] 테스트 16개: 레이아웃 고정, 삼각형 보존·순서, 한계·인덱스 범위, 경계 구 포함, 평면 콘, 샘플 3종 로드, 동시 로드 안전
- **완료 기준 충족**: bunny 69,451 삼각형 로드 0.39s, 메시렛 빌드 약 0.2s (Debug, M2 Pro)
- [x] Morton 코드 공간 정렬 후 분할 (bunny 컬링률 8% → 36%, 메시렛 시각화가 패치 형태로 개선)
- 남은 일(선택): meshoptimizer식 클러스터링으로 품질 추가 개선, 텍스처 로드는 Phase 5

### Phase 2b — GLB 최소 로더 ✅ (2026-09-06 완료)
- [x] `GLBLoader`: GLB 컨테이너 + .gltf(외부/data: URI), 노드 TRS/matrix, TRIANGLES/STRIP/FAN, 인덱스 유무, 정규화 정수 접근자
- [x] 노멀 없으면 생성, glTF UV(좌상단) → 내부 규약(좌하단) 변환
- [x] pbrMetallicRoughness baseColorFactor/baseColorTexture(bufferView·URI 이미지), 재질 캐시
- [x] Draco/sparse는 명시적 거부. `ModelLoader.load`가 확장자로 분기(Model I/O 큐 불필요)
- [x] 팔레트 PNG 텍스처(Duck) 업로드 실패 → `GPUMesh.normalizedRGBA`로 해결
- [x] 테스트 7개 (합성 .gltf, 스트립, 잘못된 magic, Duck/Avocado/Poly Pizza bunny, 프로브)
- **완료 기준 충족**: Poly Pizza bunny.glb가 변환 없이 등록·렌더링. 샘플 28개(총 ~113MB)

### Phase 3 — 메시 셰이더 렌더러 (핵심) ✅ (2026-09-05 완료)
- [x] `ShaderTypes.h`에 Uniforms/MeshletPayload/버퍼 인덱스 추가, `MeshShaders.metal` object→mesh→fragment
- [x] object: 프러스텀(경계 구) + 노멀 콘 컬링, threadgroup atomic으로 페이로드 압축, 보이는 메시렛 수 atomic 카운터
- [x] mesh: 메시렛 1개/스레드그룹, set_vertex/set_index/set_primitive(meshletID)
- [x] fragment: 2광원 + 스펙큘러, 뒷면 노멀 뒤집기, 디버그(메시렛 색/노멀)
- [x] `Renderer`: MTLMeshRenderPipelineDescriptor, 트리플 버퍼링, `drawMeshThreadgroups`, GPU 시간·가시 메시렛 통계, 오프스크린 렌더 지원
- [x] `OrbitCamera` + `InteractiveMTKView` 제스처 (macOS: 드래그 회전/휠·핀치 줌/우클릭·⌥드래그 팬, iOS: 1지 회전/2지 팬/핀치 줌)
- [x] `ModelViewerView`: 로드 → 메시렛 빌드 → 렌더러, 툴바(표시 모드·컬링·와이어프레임·정보 시트), 하단 통계
- [x] 테스트 5개: 파이프라인 생성, 평면 렌더 커버리지, 콘 컬링으로 뒷면 평면 0개, bunny 컬링(일부만 보임) + 3모드, 프러스텀 평면
- **완료 기준 충족**: 오프스크린 테스트로 bunny가 그려지고 컬링이 동작함. 화면 확인은 사용자 검증 필요
- 메모: 래스터라이저 cullMode는 none (와인딩 뒤집힌 파일 대비). 뒷면 제거는 콘 컬링이 담당

### Phase 4 — 컬링 & 디버그 (Phase 3에서 대부분 선반영)
- [x] Object shader 프러스텀/콘 컬링, 살아남은 메시렛 수를 GPU 카운터로 읽어 오버레이 표시
- [x] 디버그 토글: 메시렛 색상 / 노멀 / 와이어프레임(`triangleFillMode`)
- [ ] Metal frame capture 로 파이프라인 검증 (Xcode GPU 캡처, 수동)
- [ ] 실기기(iPhone/iPad)에서 성능 확인
- **완료 기준**: 카메라를 돌리면 컬링된 메시렛 수가 변하고 화면 결함 없음

### Phase 5 — 마무리
- [x] **baseColor 텍스처** (2026-09-06): ModelLoader가 서브메시 재질에서 텍스처/색 추출(텍스처 우선, usdz는 loadTextures),
  MeshletBuilder가 재질별로 묶고 `Meshlet.materialIndex` 기록, GPUMesh가 sRGB 밉맵 텍스처 + `Material` 인자 버퍼(리소스 ID) 생성,
  fragment가 `useResources`된 텍스처를 직접 샘플링. 테스트 6개 추가(총 37개)
- [x] 오프스크린 렌더 → PNG (`Renderer.snapshot`, README 스크린샷 생성에 사용)
- [x] 썸네일 (2026-09-06): `ThumbnailStore`가 행 표시 시 요청을 큐에 넣고 한 번에 하나씩 로드→메시렛→snapshot(320×240) → Documents/Thumbnails/<id>.png.
  삭제 시 무효화. 첫 실행 25개 생성 약 10초(M2 Pro). 테스트 2개 추가(총 39개)
- [ ] 큰 모델 로딩 진행률, 에러 처리(손상 파일, 미지원 포맷)
- [ ] (선택) glTF 로더, (선택) meshoptimizer 포팅으로 메시렛 품질 개선, (선택) 다중 LOD

## 6. 프로젝트 스킬: `fetch-3d-model`

위치: `.claude/skills/fetch-3d-model/SKILL.md` (작성 완료)

- **역할**: 무료 사이트에서 3D 모델을 내려받아 `Resources/Samples/<이름>/`에 넣고 `MODELS.md`에 출처·라이선스를 기록
- **소스 (동작 확인함. Sketchfab·Poly Pizza는 키 필요)**
  1. Poly Haven API — CC0, **usdc** 직접 다운로드 (Model I/O가 바로 읽음) + 텍스처
  2. alecjacobson/common-3d-test-models — OBJ 표준 테스트 메시 (bunny, armadillo, teapot…)
  3. Stanford 3D Scanning Repository — PLY 고해상도 스캔, 메시렛 부하 테스트용
  4. Sketchfab Data API — 모델별 CC, **usdz** 직접 다운로드(300초 만료 URL). 키는 `.env.local`의 `SKETCHFAB_API_KEY`
  5. Poly Pizza API — CC0/CC-BY 로우폴리 GLB. 키는 `.env.local`의 `POLY_PIZZA_API_KEY`
  6. Khronos glTF-Sample-Assets — GLB 렌더러 호환성 테스트
- **키 파일**: `.env.local` (gitignore됨, 사용자 제공). 스킬은 파일에서 읽고 값은 출력하지 않음
- **제외**: Smithsonian(브라우저 세션 필요), Apple Quick Look 갤러리(직접 다운로드 URL 없음)
- **GLB 전용 소스(5, 6)**: Phase 2b GLB 로더 전까지는 Blender MCP 변환이 있을 때만 받음
- **앱 로더와의 연결**: 스킬이 받는 포맷(OBJ/PLY/STL/USD*)이 `ModelLoader`의 지원 포맷과 동일하도록 유지.
  포맷을 앱에 추가하면 SKILL.md의 포맷 목록도 같이 갱신
- **Phase 1에서 사용**: 번들 샘플로 `stanford-bunny.obj` + Poly Haven 모델 1개를 이 스킬로 받아 리스트 초기 항목으로 등록

## 7. 리스크와 대응

| 리스크 | 대응 |
|---|---|
| 시뮬레이터에서 메시 셰이더 불가 | macOS 타깃으로 개발·검증, iOS는 실기기에서 확인 |
| Model I/O가 glTF 미지원 | Phase 2b에서 삼각형 전용 최소 GLB 파서 작성. 스키닝·애니메이션·Draco 압축은 범위 밖으로 명시 |
| API 키 노출 | `.env.local`만 사용, `.gitignore` 등록 완료. 스킬은 파일에서 읽고 값을 출력하지 않음 |
| libusd 동시 로드 크래시 | Model I/O 호출을 단일 액터로 직렬화 (ModelProbe 참고) |
| 대형 모델의 메시렛 빌드 시간 | 백그라운드 Task + 진행률, 결과를 캐시 파일로 저장(선택) |
| 메시렛 크기와 `threadsPerMeshThreadgroup` 불일치 | 상수를 `ShaderTypes.h` 한 곳에 두고 Swift/MSL이 공유 |
| pbxproj 충돌 | XcodeGen 단일 소스. `.xcodeproj`는 gitignore, `project.yml`만 커밋 |

## 8. 첫 마일스톤

Phase 0 → 1 → 2 → 3 을 순서대로 진행해 "리스트에서 bunny.obj 선택 → 메시 셰이더로 렌더링" 이 되는 지점이
첫 데모 목표입니다.
