<div align="center">

# DNaiApp

![Android](https://img.shields.io/badge/Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-0095D5?&style=for-the-badge&logo=kotlin&logoColor=white)
![AI](https://img.shields.io/badge/AI-NovelAI%20%7C%20Gemini%20%7C%20Claude-8A2BE2?style=for-the-badge)

</div>

NAIA, Prombot, 그리고 NaiApp 세 가지 앱의 장점을 적당히 참고하여 만든 애플리케이션입니다. 프롬봇 서비스가 사라져서 스마트폰으로 이미지 뽑기가 불편해진 나머지, AI를 고문하여 직접 만들었습니다. 

사실상 99.9% 정도를 Claude와 Gemini가 만들었습니다. 말하자면 **AI가 만든, AI 이미지 생성을 돕는 어플리케이션**입니다. 미래는 AI가 책임집니다.

<br />

## 📖 목차
* [초기 설정 방법](#초기-설정-방법)
* [프롬프트 탭 설명 1](#프롬프트-탭-설정---1)
* [프롬프트 탭 설명 2](#프롬프트-탭-설정---2)
* [히스토리 탭](#히스토리-탭)
* [img2img 탭](#img2img-탭)
* [캐릭터 탭](#캐릭터-탭)
* [와일드카드 탭](#와일드-카드-탭)
* [설정 탭](#설정-탭)

---

## ⚙️ 초기 설정 방법

<img width="379" height="768" alt="image" src="https://github.com/user-attachments/assets/9a2c9a49-97b5-4b2c-b475-1d940c9371a0" />

앱을 처음 실행한 뒤 **"설정"** 탭으로 이동해 스크롤을 내리면 `NovelAI API`와 `Gelbooru API` 설정 항목이 나타납니다. 

Gelbooru API는 랜덤 프롬프트 검색 기능을 사용하지 않는다면 필수는 아니지만, 이 앱의 핵심 목적이므로 가급적 설정을 권장합니다. Danbooru만으로 검색하는 것보다 훨씬 효율적이기 때문에 Gelbooru API를 채택했습니다. 향후 API 없이도 빠르고 원활한 검색 방식을 찾게 된다면 변경될 수 있지만, 현재로서는 속도나 성능 면에서 충분히 만족스럽습니다.

<img width="456" height="349" alt="003" src="https://github.com/user-attachments/assets/c6e21a76-1d09-434c-a743-3cd92cd46f6c" />
<img width="717" height="541" alt="004" src="https://github.com/user-attachments/assets/fc30cb73-561d-43be-8aea-e60727f1dce8" />

* NovelAI API는 널리 알려진 일반적인 방법으로 획득할 수 있습니다. 
* 토큰을 얻은 후 "토큰 저장 및 연결"을 누르면 됩니다.

<img width="529" height="182" alt="005" src="https://github.com/user-attachments/assets/6c99216d-c55e-49ef-9b2d-e6a30e459a31" />

* Gelbooru 토큰은 겔부루 사이트의 `My Account`로 접속합니다.

<img width="424" height="631" alt="006" src="https://github.com/user-attachments/assets/1d62747d-280a-41f0-a479-3c639176bc5e" />

* 계정이 없다면 위 이미지의 빨간 동그라미를 따라 회원가입을 진행합니다. 
* 가입 후 화면 하단의 `Option`을 클릭합니다.

<img width="332" height="205" alt="007" src="https://github.com/user-attachments/assets/064c13e4-6149-4584-833d-89c38e744c96" />

* Option 최하단에서 API 토큰을 확인할 수 있습니다.
* 발급된 `&api_key="내 API 키"&user_id="내 ID 숫자"` 전체를 그대로 복사하여 앱에 입력하면 자동으로 인식됩니다.

설정이 끝났다면 바로 앱을 사용하실 수 있습니다!

---

## 📝 프롬프트 탭 설정 - 1

<img width="379" height="674" alt="image" src="https://github.com/user-attachments/assets/9c47f869-bd85-4da9-b9ea-f53d499d8adf" />

### 1. 검색창 열고 닫기 (톱니바퀴)
<img width="376" height="199" alt="image" src="https://github.com/user-attachments/assets/2252f263-0d5f-459c-891a-c70b8f871c4f" />

* 윗칸은 찾을 프롬프트, 아래칸은 제거할 프롬프트를 입력합니다.
* 하단의 E, Q, S, G는 일반적인 그 등급을 의미합니다.
* 검색 시 단어에 `*`를 붙이는 위치에 따라 검색 범위가 달라집니다 (띄어쓰기는 무시됨).

| 입력 방식 | 검색 범위 |
| :--- | :--- |
| `skirt` | 'skirt' 프롬프트와 정확히 일치하는 결과 검색 |
| `*skirt` | 'skirt'로 끝나는 프롬프트 검색 |
| `skirt *` | 'skirt'로 시작하는 프롬프트 검색 |

<img width="369" height="255" alt="image" src="https://github.com/user-attachments/assets/a2c636e5-a2f6-46d5-9cb3-a77798695046" />

* 검색창에 단어를 입력하면 Danbooru 기준 사용량이 가장 많은 순서대로 태그가 미리 표시됩니다.
* Danbooru 기준 사용량 100 이상인 태그는 모두 포함되어 있으므로 대부분의 프롬프트를 찾을 수 있습니다.
* 띄어쓰기를 지원하여 센스 있게 검색해 줍니다 (예: `pla ski` 입력 시 `plaid skirt` 검색).
* 터치 시 쉼표까지 자동으로 입력되며, 창을 드래그해 목록을 확인할 수 있습니다.
* "검색" 버튼을 누르면 "검색 : n" 및 "남음 : n"이 표시됩니다.

### 2. 다음 프롬프트
톱니바퀴로 검색한 목록(랜덤으로 섞임)에서 다음 순서의 프롬프트를 가져와 "긍정적 프롬프트"에 넣어줍니다. 이때 후술할 "개별 제거"나 "조건부 트리거"가 자동으로 정제되어 적용됩니다.

### 3. 현재 프롬프트 다시 불러오기
수정한 "개별 제거"나 "조건부 트리거"가 잘 적용되었는지 확인하고 싶을 때 사용합니다. 방금 불러왔던 목록을 다시 로드합니다.

### 4. 프리셋 관리
<img width="384" height="253" alt="image" src="https://github.com/user-attachments/assets/5e27bafc-9039-4e62-914a-8579bd6f83f3" />

긍정적, 부정적, 선행, 후행, 캐릭터, 설정 총 6가지의 프리셋을 저장할 수 있습니다. 
* 긍정적, 선행, 캐릭터만 저장한 경우 개별 탭에, 그 외는 모두 '기타' 탭에 표시됩니다.
* 저장된 프리셋 상단의 그림 칸을 눌러 미리보기 이미지를 지정할 수 있습니다.
* '기타' 탭의 프리셋은 원하는 항목만 펼쳐서 가져올 수 있으나, 복사는 시스템상 한 종류만 가능합니다.

### 5. 랜덤 잠금
체크 시 "다음 프롬프트" 버튼이 눌리지 않습니다. 수동으로 프롬프트를 작성하는 도중 실수로 버튼을 누르는 참사를 방지합니다.

### 6. 자동 저장
체크하면 생성이 완료될 때마다 기기에 파일이 저장됩니다. 해제 시 "히스토리" 목록에만 올라갑니다.

### 7. 연속 생성 기능
<img width="223" height="55" alt="image" src="https://github.com/user-attachments/assets/4a4bb56b-47ea-480e-a092-99cdf64c363f" />

* 네모 버튼을 누르면 `1 -> 2 -> 3 -> 4 -> ∞` 순으로 변경되며, 이미지 생성 시 남은 숫자가 표시됩니다.
* 생성을 중간에 멈추고 싶다면 "생성중(n)..."으로 바뀐 버튼을 눌러 추가 생성을 취소할 수 있습니다.

---

## 📝 프롬프트 탭 설정 - 2

<img width="378" height="754" alt="p002" src="https://github.com/user-attachments/assets/101a4d80-5c3a-4fb0-84ce-5f1526d7d498" />

### 개별 제거 프롬프트
검색된 프롬프트 목록을 불러올 때, 여기에 등록된 프롬프트를 자동으로 지워줍니다.

| 문법 | 설명 |
| :--- | :--- |
| `skirt` | 정확히 'skirt'인 프롬프트 제거 |
| `*skirt` | 'skirt'로 끝나는 프롬프트 제거 |
| `skirt*` | 'skirt'로 시작하는 프롬프트 제거 |
| `*skirt *` | 'skirt'가 포함된 모든 프롬프트 제거 (띄어쓰기 무관) |

### 조건부 트리거 
최대한 NAIA와 비슷하게 구현했으나 약간 다릅니다. 줄바꿈이 나올 때까지를 하나의 명령어로 인식합니다.

| 예시 문법 | 작동 원리 |
| :--- | :--- |
| `(cat):cat = dog` | cat이 있다면 dog로 변경 |
| `(cat*):cat = dog` | cat으로 시작하는 프롬프트가 있다면, cat 부분을 dog로 변경 |
| `(cat*):cat*^dog` | cat으로 시작하는 프롬프트 중 cat 부분을 dog로 변경 (예: cat ears -> dog ears) |
| `(e\|q):prefix=nsfw` | Rating:e 또는 Rating:q가 있다면 긍정적 프롬프트 맨 앞에 nsfw 추가 (suffix는 맨 뒤) |
| `(white panties&skirt):suffix=windlift` | white panties와 skirt가 모두 있다면 긍정적 프롬프트 맨 뒤에 windlift 추가 |
| `(sleeping):sleeping = sleeping, 2::closed eyes ::, nightgown` | sleeping을 지정한 긴 프롬프트 구문으로 통째로 교체 |

### 이미지 상호작용
생성된 큰 이미지를 꾹 누르면 관련 옵션 창이 표시됩니다. 직관적으로 구성되어 있어 바로 사용하실 수 있습니다.

---

## 🕒 히스토리 탭

<img width="379" height="664" alt="image" src="https://github.com/user-attachments/assets/4a2cbd14-ed5b-4c47-b4cc-2f7448c5e27f" />

* 하단의 화살표 버튼은 섬네일 미리보기가 생성되기 전 옆 이미지를 보기 위한 용도입니다.
* 섬네일을 꾹 누르면 삭제 메뉴가 나타납니다.

### 프롬프트 확인
아이콘을 누르면 4가지 항목이 나타나며, 해당 이미지가 가진 프롬프트를 확인할 수 있습니다.

### 이미지 불러오기
스마트폰 갤러리에서 이미지를 선택해 히스토리 목록 끝에 추가합니다. 생성한 이미지처럼 꾹 눌러 상호작용하거나 프롬프트를 확인할 수 있습니다.

---

## 🎨 img2img 탭

<img width="380" height="630" alt="image" src="https://github.com/user-attachments/assets/cbb45243-d957-4ccc-a533-2481e6de83f1" />

이미지를 꾹 눌러 '이미지 수정하기(i2i)'를 선택하면 해당 이미지가 i2i 탭으로 이동합니다.

* **인페인트(Inpaint):** 좌측 상단. 마스킹된 영역을 프롬프트에 따라 수정합니다.
* **업스케일(Upscale):** 우측 상단. 현재 이미지를 4배 확대하여 저장합니다. (Anlas 소모가 아까워서 자동으로 폴더에 저장되도록 설정했습니다).
* 두 기능 모두 실행 후 자동으로 히스토리 탭으로 이동합니다.

<img width="380" height="313" alt="image" src="https://github.com/user-attachments/assets/3709a0e4-1110-4961-b4a6-1747b5605b63" />

> **💡 조작 관련 중요 팁**
> 마스크를 그리는 중 화면이 제멋대로 스크롤되는 것을 방지하기 위해 특수하게 설계되었습니다.
> * **빨간색 영역:** 터치 후 드래그 시 스크롤이 작동하지 않습니다 (마스킹용).
> * **노란색 영역:** 한 번 터치한 후 드래그해야 스크롤이 작동합니다.

---

## 👥 캐릭터 탭

<img width="371" height="578" alt="image" src="https://github.com/user-attachments/assets/5460c966-977d-4567-8f36-e718f3116260" />

* `+` 버튼을 눌러 캐릭터 개수를 계속 추가할 수 있습니다.
* 눈 모양 아이콘을 눌러 캐릭터를 ON/OFF 할 수 있습니다 (보라색/회색으로 표시됨). 여러 캐릭터를 만들어두고 필요한 것만 켜고 끄면서 사용할 때 매우 유용합니다.

---

## 🃏 와일드 카드 탭

<img width="377" height="470" alt="image" src="https://github.com/user-attachments/assets/bd14c22d-a93a-4e61-8d46-e458f487d818" />

미리 설정해 둔 확률에 따라 랜덤한 태그를 뽑는 기능입니다.

* 작성 중 상단에 미리보기가 실시간으로 표시됩니다.
* 확률 가중치를 조절할 수 있습니다. 예를 들어 전체 합이 450일 때, 가중치가 할당된 `skirt`는 약 44%, `pants`는 약 11% 확률로 등장하게 됩니다. 
* 가중치를 적지 않고 프롬프트만 3개 넣으면 각각 33%의 확률로 동일하게 뽑힙니다.

---

## ⚙️ 설정 탭

<img width="374" height="746" alt="image" src="https://github.com/user-attachments/assets/899e66d2-6d33-42ce-993a-7573cbaeb067" />

* **이미지 갯수 표시:** 이번 세션에서 저장한 이미지 개수가 표시됩니다.
* **대형 이미지 숨기기:** 설정에서 끄면 "캐릭터 탭"과 "와일드카드 탭" 상단의 큰 이미지가 숨겨집니다.
* **저장 경로 & 파일 이름 설정:** 저장 경로는 버튼을 누르거나 수동으로 작성할 수 있습니다. 
* 파일명 규칙: `{yy}`(연도), `{mm}`(월), `{dd}`(일), `{time}`(시간), `{count}`(번호). 나머지는 적은 그대로 파일명에 반영됩니다.

> 🔒 **보안 안내**
> 입력하신 API 토큰은 오직 사용자의 기기(로컬)에만 저장되며 외부로 전송되지 않습니다. 앱 삭제 시 모든 데이터는 함께 완전히 삭제됩니다.
