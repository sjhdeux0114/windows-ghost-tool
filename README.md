# Windows Ghost 설치 도구

Windows 설치 ISO로 Hyper-V 기준 VM을 만들고, Sysprep으로 일반화한 뒤 Ghost 이미지(`.gho`)를 생성하는 Windows 데스크톱 도구입니다. GHO를 물리 HDD/SSD 전체에 복원하거나, 생성했던 가상 Windows 내역과 디스크를 정리할 수 있습니다.

## 주요 기능

- **ISO → GHO 파일 만들기:** ISO 버전·아키텍처·에디션 판별, Windows 이미지 적용, VM 초기 설정, Sysprep, Ghost 캡처 및 무결성 검사.
- **VM 사양 선택:** PC의 RAM·사용 가능한 메모리·논리 CPU 수를 표시하고 RAM과 CPU 개수를 직접 설정.
- **VM 화면 확인:** VM 시작 후 연결 창을 열어 설치 진행 상태 확인.
- **GHO → HDD에 설치하기:** 대상 확인 → 이미지 검사 → 실제 복원. 검사와 복원 단계 표시.
- **가상 윈도우 내역:** 이름·생성 시각·상태·작업 폴더 목록과 삭제 기능. VM 등록·가상 디스크·작업 내역을 함께 정리하고 완성된 GHO는 보존.
- **진단 로그:** 단계별 명령·종료 코드·설치 및 Sysprep 기록.

## 실행 환경

Windows 10/11의 Hyper-V 지원 에디션, BIOS/UEFI 가상화, Hyper-V 관리 도구, 관리자 권한이 필요합니다. Home 에디션은 지원하지 않습니다. Windows PowerShell 5.1과 .NET Framework 4.x를 사용합니다.

적법하게 사용할 수 있는 Windows ISO와 `Ghost64.exe`를 별도로 준비해야 합니다. **ISO, Ghost 실행 파일, 생성된 이미지, VM 디스크와 개인 로그는 이 저장소에 포함하지 않습니다.**

| Windows | VM 디스크 | 작업 드라이브 여유 공간 |
|---|---|---|
| Windows 7/10 | 40GiB | 128GiB 이상 |
| Windows 11 | 64GiB | 200GiB 이상 |

RAM과 CPU는 생성 전에 선택합니다. PC 자원을 고려해 기본값을 제안하며, 호스트 운영체제에 사용할 자원을 남겨야 합니다.

## 빌드

저장소 폴더에서 Windows PowerShell로 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

결과는 `GhostImageApp.exe`입니다. 앱이 실행 중이면 다른 이름으로 빌드합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -OutputName GhostImageAppFix.exe
```

Windows에 포함된 .NET Framework C# 컴파일러를 사용합니다. EXE와 함께 `AutoBuild.ps1`, `GuestSeal.ps1`, `VmHistory.ps1`, 별도로 준비한 `Ghost64.exe`를 같은 폴더에 두세요. `VmWizard.ps1`은 별도 수동 VM 준비 도구입니다.

## 사용 방법

### ISO로 GHO 만들기

1. 앱을 관리자 권한으로 실행하고 **ISO → GHO 파일 만들기**를 선택합니다.
2. ISO와 GHO 저장 위치를 선택합니다. 작업 폴더도 GHO 저장 드라이브에 생성됩니다.
3. VM RAM과 CPU 개수를 선택합니다.
4. 자동으로 열린 VM 화면에서 초기 설정을 확인합니다. Sysprep 완료 전 강제 종료·재부팅하지 마세요.
5. 일반화 완료 상태를 검증하고 Ghost 이미지 생성과 무결성 검사를 수행합니다. 완료 로그와 `result.json`으로 결과를 확인합니다.

Windows 7 및 x86은 BIOS/MBR, Windows 10 x64는 UEFI/GPT를 사용합니다. Windows 11은 UEFI와 가상 TPM을 사용합니다. Pro/Professional 에디션이 있으면 우선 선택합니다. ARM, Windows Server, 분할 SWM은 지원하지 않습니다. 네트워크 연결·Windows 업데이트·별도 앱 설치·정품 인증은 자동화하지 않습니다.

감사 모드에서 별도 SYSTEM 예약 작업으로 봉인 스크립트를 실행합니다. VM 종료만으로 성공을 판단하지 않고 `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE` 상태를 확인합니다. 설치/Sysprep 대기 제한은 120분이며 시간 초과 시 VM을 강제 종료하지 않습니다.

BCDBoot의 BCD 하이브 충돌(종료 코드 183) 시 작업 폴더에 별도 BCD를 구성하여 해당 VM의 EFI 파티션에 배치합니다. 호스트 BCD 하이브를 해제하거나 수정하지 않습니다.

### GHO를 HDD/SSD에 복원하기

1. **GHO → HDD에 설치하기**에서 대상 물리 디스크와 GHO를 선택합니다.
2. 시작 전에 표시되는 덮어쓰기 확인창에서 모델·용량·일련번호·원본 경로를 확인합니다.
3. 첫 Ghost 실행은 이미지 무결성 검사이며, 대상 HDD에 쓰지 않습니다.
4. 통과하면 실제 복원을 한 번 실행합니다. Ghost의 최종 확인에서도 대상 디스크를 확인하세요.

**대상 디스크의 모든 파티션과 데이터가 삭제됩니다.** 시스템·부팅·페이지 파일·앱·GHO 원본 디스크 및 읽기 전용/가상 디스크는 차단합니다. 실행 직전에 대상 식별 정보를 다시 조회합니다. 디스크 번호가 비연속이거나 파일의 물리 위치를 확인할 수 없으면 중단합니다. 복원 중 디스크를 연결·분리하지 마세요.

Ghost를 취소한 경우 종료 코드 0만으로 복원 완료를 판단할 수 없습니다. UEFI/GPT 이미지는 UEFI, BIOS/MBR 이미지는 Legacy BIOS 부팅 환경이 필요합니다. 실제 PC의 드라이버·라이선스·복원 후 부팅은 별도 확인이 필요합니다.

### 가상 Windows 내역 삭제하기

1. 메인 메뉴 하단의 **가상 윈도우 내역**을 엽니다.
2. 항목을 선택하고 **삭제하기**를 누릅니다.
3. VM 이름과 작업 폴더를 확인하고 삭제를 승인합니다.

VM 등록·가상 디스크·변환 파일·해당 작업 폴더의 로그와 내역을 삭제합니다. 완성된 GHO는 보존합니다. 작업 폴더 안에 GHO가 있으면 먼저 다른 위치로 옮겨야 합니다. 실행 중인 VM, 연결되거나 다른 VM이 공유하는 디스크, 작업 폴더 밖의 디스크 및 연결 경로는 삭제를 차단합니다. 삭제는 되돌릴 수 없습니다.

앱 폴더의 `AutoBuilds`, `C:\GhostAutoBuilds`, 앱이 기록한 사용자 지정 작업 위치와 수동 VM 프로젝트를 검색합니다.

## 소스 구성

| 파일 | 역할 |
|---|---|
| `GhostImageApp.cs` | 메인 메뉴, 디스크 조회, 복원 대상 보호 정책 |
| `AutoBuildForm.cs` | ISO·저장 위치·VM 사양 선택, 진행 표시 |
| `AutoBuild.ps1` | ISO 판별, VM 준비, 봉인 상태 검증, Ghost 생성·검사 |
| `GuestSeal.ps1` | VM 내부 초기 설정 대기, Sysprep |
| `RestoreForm.cs` | 이미지 검사, 물리 디스크 복원 |
| `VmHistoryForm.cs`, `VmHistory.ps1` | 내역 목록, VM·작업 파일 삭제 |
| `VmWizard.ps1` | 별도 수동 VM 준비 도구 |
| `build.ps1`, `app.manifest` | 빌드, 관리자 실행 설정 |
| `tests/` | 자동 빌드 로직, 복원 정책, 내역 삭제 보호 테스트 |

## 테스트

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AutoBuild.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-VmHistory.ps1

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /target:exe /platform:x64 /out:tests\SafetyTests.exe /main:SafetyTests /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Management.dll /reference:System.Web.Extensions.dll GhostImageApp.cs AutoBuildForm.cs RestoreForm.cs VmHistoryForm.cs tests\SafetyTests.cs
.\tests\SafetyTests.exe
```

삭제 테스트는 임시 폴더와 가짜 Hyper-V 모듈을 사용합니다. 실제 VM과 물리 디스크는 삭제하지 않습니다. 버전 판별·응답 파일 XML·봉인 상태·VHD 변환·외부 명령 출력, 복원 보호 정책 9개, 내역 소유권·경로 경계·연결 폴더 차단·실행 중 VM 차단·VM 등록과 파일 삭제·GHO 보존을 검증합니다.

## 검증 범위와 로그

Windows 10 Pro x64에서 VM 설치·감사 모드·Sysprep·UEFI 부팅 구성·GHO 생성과 Ghost 무결성 검사를 실제로 통과했습니다. 물리 디스크 복원 명령은 실행 로그로 확인했지만, **복원한 디스크로 실제 PC가 부팅하는지 검증은 완료하지 않았습니다.** Windows 7/11과 모든 하드웨어 조합을 실환경에서 검증한 것은 아닙니다. 사용한 Ghost 버전은 12.0.0.8023입니다.

빌드 로그는 GHO 저장 폴더의 `AutoBuilds/<작업ID>/`, 복원 로그는 앱 폴더의 `RestoreLogs/<작업ID>/`에 기록됩니다. `build.log`, `events.jsonl`, `error-details.txt`, `GuestLogs`, `SysprepLogs`, `result.json`, `exit-code.txt`로 진행과 결과를 확인합니다. VM 내부 봉인 로그는 `C:\GhostBuild\seal.log`입니다. 로컬 로그에는 파일 경로·계정·디스크 식별 정보가 포함될 수 있으므로 저장소에 업로드하지 않습니다.

## 참고 문서

- [Microsoft BCDBoot](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di)
- [Microsoft BCDEdit](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdedit-command-line-options)
- [Windows 설치 상태](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-states)
- [Broadcom Ghost 명령 옵션](https://knowledge.broadcom.com/external/article?articleNumber=152308)
- [Ghost 가상 디스크 로딩](https://knowledge.broadcom.com/external/article/151747)
