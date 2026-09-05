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
| 2차 포맷 | **GLB** (Phase 2b, 자체 최소 파서) | Poly Pizza·Khronos 샘플이 전부 GLB. 삼각형 메시만 지원(스키닝/애니메이션 제외), 텍스처는 baseColor만 |
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
├── Viewer/                          # 2번 화면: 렌더링
│   ├── ModelViewerView.swift        # 화면 컨테이너, 로딩 상태, 통계 오버레이, 디버그 토글
│   ├── MetalView.swift              # MTKView ↔ SwiftUI 브리지 (UIViewRepresentable / NSViewRepresentable)
│   ├── OrbitCamera.swift            # 드래그 회전, 핀치/휠 줌, 팬
│   └── Gestures.swift
├── Rendering/
│   ├── Renderer.swift               # MTKViewDelegate, 커맨드 인코딩, drawMeshThreadgroups
│   ├── MeshPipeline.swift           # MTLMeshRenderPipelineDescriptor 생성
│   ├── GPUMesh.swift                # 메시렛 버퍼 세트 (MTLBuffer 묶음)
│   └── Shaders/
│       ├── ShaderTypes.h            # Swift/MSL 공유 구조체 (Uniforms, Meshlet, Payload)
│       ├── MeshShaders.metal        # object / mesh / fragment
│       └── Fallback.metal           # (선택) 미지원 기기용 일반 vertex 파이프라인
├── Import/
│   ├── ModelProbe.swift             # 정점/삼각형 수만 세는 경량 로더 (직렬 액터, 완료)
│   ├── ModelLoader.swift            # MDLAsset → 중간 표현(positions, normals, uvs, indices)
│   ├── MeshletBuilder.swift         # 삼각형 → 메시렛 분할 + 경계 구(sphere)/노멀 콘 계산
│   └── ModelImportError.swift
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

### Phase 2 — 로딩 + 메시렛 빌더 (CPU)
- [ ] `ModelLoader`: MDLAsset → 서브메시 병합, 정점 포맷 정규화(position/normal/uv), 노멀 없으면 생성
- [ ] `MeshletBuilder`: 인덱스 순서 기반 그리디 분할(1차) → 경계 구 + 노멀 콘 계산
- [ ] 단위 테스트: 모든 삼각형 보존, 한계 초과 없음, 인덱스 범위
- **완료 기준**: bunny.obj 로드 후 메시렛 수/정점 수가 콘솔과 리스트 행에 표시

### Phase 2b — GLB 최소 로더 (Phase 3 이후로 미룰 수 있음)
- [ ] GLB 컨테이너(JSON 청크 + BIN 청크) 파싱, `meshes[].primitives` 중 TRIANGLES만 처리
- [ ] accessor → position/normal/uv/indices 추출, 노드 변환 행렬 적용해 단일 메시로 병합
- [ ] baseColorTexture(PNG/JPEG 내장) 1장만 로드, 나머지 재질 무시
- [ ] 단위 테스트: Khronos `Duck.glb`, Poly Pizza 모델 1개 로드
- **완료 기준**: Poly Pizza에서 받은 .glb가 변환 없이 리스트에 추가되고 렌더링

### Phase 3 — 메시 셰이더 렌더러 (핵심)
- [ ] `ShaderTypes.h` 공유 구조체, `MeshShaders.metal` object/mesh/fragment
- [ ] `MeshPipeline`: `MTLMeshRenderPipelineDescriptor` + depth state
- [ ] `Renderer`: 카메라 유니폼, 트리플 버퍼링, `drawMeshThreadgroups`
- [ ] `OrbitCamera` + 제스처, 모델 경계로 자동 프레이밍
- **완료 기준**: 리스트에서 모델 탭 → 회전/줌 가능한 셰이딩된 모델 표시

### Phase 4 — 컬링 & 디버그
- [ ] Object shader 프러스텀/콘 컬링, 살아남은 메시렛 수를 GPU 카운터로 읽어 오버레이 표시
- [ ] 디버그 토글: 메시렛 색상 / 노멀 / 와이어프레임(`triangleFillMode`)
- [ ] Metal frame capture 로 파이프라인 검증
- **완료 기준**: 카메라를 돌리면 컬링된 메시렛 수가 변하고 화면 결함 없음

### Phase 5 — 마무리
- [ ] 썸네일: 뷰어에서 오프스크린 렌더 → PNG 저장 → 리스트에 표시
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
