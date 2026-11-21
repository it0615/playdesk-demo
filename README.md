# PlayDesk

PlayDesk는 Apple Silicon Mac에서 Android Emulator를 관리하는 SwiftUI 데스크톱 앱입니다. AVD를 선택하고 시작·종료하거나 앱 목록을 열며, 앱별 키 매핑을 로컬 JSON에 저장할 수 있습니다.

## 요구 사항

- Apple Silicon Mac, macOS 13 이상, Swift 5.10 이상
- Android Emulator와 adb, 별도로 구성한 ARM64 AVD
- SDK와 가상 기기 이미지, APK는 이 프로젝트에 포함하지 않습니다.

## 빌드

```sh
./scripts/build-app.sh
```

빌드 결과는 `dist/`에 만들어집니다. 이 스크립트는 Swift 컴파일러와 macOS SDK를 사용해 개발용 앱 번들을 생성하고, 로컬 실행용 임시 서명을 적용합니다. 기존 앱을 설치하거나 교체하지 않습니다. 소스 공개본에는 설치 파일을 포함하지 않습니다.

## 테스트

```sh
./scripts/test-profiles.sh
./scripts/test-bridge-input.sh
./scripts/test-isolated-model.sh
```

테스트는 가상 프로필과 격리된 실행 환경을 사용합니다. 실제 AVD 부팅과 게임 입력 검증은 별도입니다. [프로필 예제](examples/profiles.example.json)에는 가상 패키지 이름과 샘플 좌표만 들어 있습니다.

[구현 구조](ARCHITECTURE.md)
