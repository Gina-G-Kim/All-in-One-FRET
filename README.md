# All in One FRET

[![FRET](https://img.shields.io/badge/FRET-v3.1.0-0a84ff)](https://github.com/NASA-SW-VnV/fret/releases/tag/v3.1.0)
[![Docker](https://img.shields.io/badge/Docker-required-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/get-docker/)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](https://docs.docker.com/desktop/)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](https://www.apache.org/licenses/LICENSE-2.0)

브라우저로 접속해 사용하는 NASA FRET 실습용 Docker 환경입니다. 예제 프로젝트(caseStudies)가 컨테이너 안에 포함되어 있으며, FRET의 Import Project 메뉴로 직접 불러오면 됩니다.

*Windows 환경은 Git Bash 또는 WSL에서 실행하세요.*

원본 프로젝트: https://github.com/NASA-SW-VnV/fret

## 예제 프로젝트 (caseStudies)

컨테이너 내부 `/opt/fret/caseStudies` 경로에 예제 프로젝트가 들어 있습니다. Import 대화상자의 왼쪽 목록(Home, Desktop, fret-electron)에는 나타나지 않으니 **Other Locations**를 클릭하거나 `Ctrl+L`로 주소창을 연 뒤 아래 경로를 직접 입력하세요.

| 프로젝트 | 경로 |
|---|---|
| FiniteStateMachine | `/opt/fret/caseStudies/FiniteStateMachine/fsm_reqts_and_vars.json` |
| LMCPS | `/opt/fret/caseStudies/LMCPS/LM_requirements.json` |
| LiftPlusCruise (full) | `/opt/fret/caseStudies/LiftPlusCruise/LPC_full_reqts_and_vars.json` |
| LiftPlusCruise (mini) | `/opt/fret/caseStudies/LiftPlusCruise/LPC_mini_reqts_and_vars.json` |
| LiquidMixer | `/opt/fret/caseStudies/LiquidMixer/LM_reqts_and_vars.json` |

## 빌드

```
./fret.sh build
```

### 빌드 옵션

| 옵션 | 설치되는 도구 |
|---|---|
| `--with-nusmv` | NuSMV |
| `--with-jkind` | JKind |
| `--with-kind2` | Kind2 |
| `--with-z3` | Z3 |
| `--with-aeval` | AE-VAL |
| `-all` | 모든 도구 |

빌드는 누적됩니다. 이미 설치된 도구는 이후 빌드에서 옵션을 다시 넣지 않아도 유지됩니다.

```
./fret.sh build --with-z3      # z3 설치
./fret.sh build --with-kind2   # z3 유지 + kind2 추가
./fret.sh build -all           # 나머지(nusmv, jkind) 전부 추가
```

특정 도구를 빼려면 이미지를 삭제하고 원하는 옵션으로 다시 빌드하면 됩니다.

```
docker rmi fret-lab
```

## 실행

```
./fret.sh start     # 실행 + 브라우저 자동 오픈
./fret.sh stop      # 종료
./fret.sh restart   # 재시작
./fret.sh status    # 상태 확인
./fret.sh logs      # 로그 확인
```

**JKind은 JVM 기반이라 Kind2보다 메모리를 많이 쓰고 느립니다.** 사양이 낮은 PC에서는 Kind2 / Kind2 + MBP 사용을 권장합니다. 

환경변수 등 세부 옵션은 `./fret.sh help` 참고.

