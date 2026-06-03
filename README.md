<div align="center">

# DNaiApp

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![AI](https://img.shields.io/badge/AI-NovelAI%20%7C%20Gemini%20%7C%20Claude-8A2BE2?style=for-the-badge)

</div>

NAIA랑 Prombot 그리고 NaiApp 이 3가지를 적당히 배낀 파쿠리 어플임

프롬봇이 사라져서 스마트폰으로 이미지 뽑기가 불편한 나머지 Ai를 고문해서 만들었음

사실상 99.9% 정도를 Claude와 Gemini가 만든 말하자면 Ai가 만든 Ai 이미지 만들기를 돕는 어플리케이션

미래는 Ai가 책임진다.

<br />

## 📖 목차
* [초기 설정 방법](#초기-설정-방법)
* [프롬프트 탭 설명 1](#프롬프트-탭-설명---1)
* [프롬프트 탭 설명 2](#프롬프트-탭-설명---2)
* [히스토리 탭](#히스토리-탭)
* [img2img 탭](#img2img-탭)
* [캐릭터 탭](#캐릭터-탭)
* [와일드 카드 탭](#와일드-카드-탭)
* [설정 탭](#설정-탭)

---

<a id="초기-설정-방법"></a>
## ⚙️ 초기 설정 방법

<img width="374" height="389" alt="image" src="https://github.com/user-attachments/assets/2320be40-b18f-482f-b05d-c2e045ad1481" />

<br />

처음 어플을 켠 뒤 `설정탭`으로 가서 아래로 내리면 NovelAi API랑 Gelbooru API를 입력하는 창이 있음.

Gelbooru API가 필요한 이유는 앱 특성상 검색 기능을 최대한 효율적으로 쓰기 위해서 필요한거라고 생각해주셈.

검색 기능에만 필요한 API라 없어도 다른 기능에는 지장없지만 사실 이 앱을 쓰는 이유중 하나라 쓰는걸 추천함.

<br />

<img width="456" height="349" alt="003" src="https://github.com/user-attachments/assets/c6e21a76-1d09-434c-a743-3cd92cd46f6c" />
<img width="717" height="541" alt="004" src="https://github.com/user-attachments/assets/fc30cb73-561d-43be-8aea-e60727f1dce8" />


NovelAi API는 검색해보면 금방 나오니까 한번 찾아보면 되고

<br />

<img width="529" height="182" alt="005" src="https://github.com/user-attachments/assets/6c99216d-c55e-49ef-9b2d-e6a30e459a31" />


Gelbooru 토큰은 겔부루 사이트에서 My Account 를 누르고

<br />

<img width="424" height="631" alt="006" src="https://github.com/user-attachments/assets/1d62747d-280a-41f0-a479-3c639176bc5e" />


계정이 있고 이미 로그인 되어있다면 여기서 Option을 눌러서

<br />

<img width="332" height="205" alt="007" src="https://github.com/user-attachments/assets/064c13e4-6149-4584-833d-89c38e744c96" />


맨 아래에 Api~로 시작하는 창에 API가 있음.

형식은 `&api_key="내 API 키"&user_id="내 ID 숫자"` 로 되어 있고 이거 전체를 그대로 복사해서 넣으면 됨

NovelAi API는 넣는 순간 알아서 인증되니까 따로 버튼을 누를 필요는 없음

<br />

<img width="420" height="297" alt="image" src="https://github.com/user-attachments/assets/faf74e6b-bf9a-4d99-ab84-a21348c25400" />
<img width="447" height="313" alt="image" src="https://github.com/user-attachments/assets/8b14c12a-ff16-44a7-be31-44160d6f75a1" />


만약 아이디가 없으면 My Account를 눌렀을때 이렇게(왼쪽 스샷) 뜨니까 빨간 동그라미를 따라가서 새로 가입하면 됨

<br />
<br />

여기까지 했으면 이제 바로 사용 가능

---
---

<a id="프롬프트-탭-설명---1"></a>
## 📝 프롬프트 탭 설명 - 1

<img width="379" height="674" alt="image" src="https://github.com/user-attachments/assets/7afe6a30-e3d1-4077-b1a6-e32d5fa31d26" />



하나씩 설명하면

---

### 1. 톱니바퀴(검색창 열고 닫기)

<img width="376" height="200" alt="image" src="https://github.com/user-attachments/assets/2de96084-6b2f-4ce7-ba41-9f0e29ffa9c5" />


톱니바퀴 아이콘을 누르면 스크린샷처럼 화면이 나옴. NAIA를 만드신 분께는 언제나 감사합니다.

윗칸은 찾을 프롬프트, 아래칸은 제외할 프롬프트임

아래 E, Q, S, G 는 각각 

| Rating | 설명 |
| :--- | :--- |
| `Explicit` | 성행위를 포함한 수위 |
| `Questionable` | 중요부위 노출이 있는 수위 |
| `Sensitive` | 속옷이 보이는 정도의 수위 |
| `General` | 건전한 그림 |

이고 체크한 Rating이 포함된 그림을 찾게해줌.

윗칸에 1girl, skirt 로 하면 1girl, skirt가 포함된 모든 결과가 검색되고

아랫칸에 serafuku를 넣으면 1girl, skirt가 둘 다 포함되어있는 결과 중 serafuku가 포함된 결과를 제외함.

<br />

또한 검색할때 `*`을 붙인 곳에 따라 범위가 바뀌고 윗칸 아래칸에서 모두 사용 가능함.

| 입력 예시 | 검색 방식 |
| :--- | :--- |
| `skirt` | 정확히 skirt 프롬프트 검색 |
| `*skirt` | skirt로 끝나는 프롬프트 |
| `skirt*` | skirt로 시작하는 프롬프트 |
| `*skirt*` | skirt가 들어간 모든 프롬프트 |

<br />

그리고 여러 프롬프트를 동시에 찾고싶은 경우가 있는데 그런 경우엔

`{A|B}` 식으로 검색하면 A가 포함된 결과와 B가 포함된 결과를 모두 찾아줌.

<br />

<img width="369" height="255" alt="image" src="https://github.com/user-attachments/assets/a2c636e5-a2f6-46d5-9cb3-a77798695046" />


검색창에는 단어를 입력하면 Danbooru 기준 가장 사용량이 많은 순으로 입력한 글자로 시작하는 프롬프트가 미리 표시됨

터치하면 그대로 쉼표까지 입력되고 저 창을 드래그하면 아래로 목록을 내릴 수 있음

Danbooru 기준 사용량 100이상은 모두 넣어뒀으니 애지간한 프롬프트는 다 있을 것

<br />

만약 검색량을 넘게되면 그 뒤로는 단어앞에 `*`을 붙여서 검색한 단어를 포함한 또는 단어로 끝나는 프롬프트들을 표시해줌

그리고 띄어쓰기 하면 눈치있게 잘 찾아주게 해뒀음 (pla ski = plaid skirt가 나옴)

다 정하고 `검색` 버튼을 눌러서 조건에 맞는 프롬프트들이 있다면

`검색 : n` 이랑 `남음 : n` 에 숫자가 생기면서 검색이 완료됨.

---

### 2. 다음 프롬프트

<img width="366" height="59" alt="image" src="https://github.com/user-attachments/assets/0fde7a2f-a396-4f39-aea5-fc1e09c74bcd" />


검색한 결과를 하나씩 `긍정적 프롬프트`에 넣는 역할을 해줌.

이 과정에서 원래 `긍정적`에 들어있던 모든 프롬프트는 사라짐.

아래에서 다시 후술하겠지만 `개별 제거`나 `조건부 트리거`는 이 과정에서 정제됨

Anals 아래에 `검색` 옆에 숫자가 있어야 작동되고 누를때마다 `남음`이 하나씩 줄어듬.

`남음`이 0일때 누르면 다시 처음으로 돌아가서 저장된 프롬프트를 불러옴.

---

### 3. 현재 프롬프트 다시 불러오기

<img width="370" height="54" alt="image" src="https://github.com/user-attachments/assets/0043887f-9433-4ea3-a9cf-43f430aba279" />


만약 `다음 프롬프트`로 프롬프트를 불러왔는데 "아~ 여기서 딱 이거만 없었으면 좋겠는데" 같은 생각이 들 때

`개별 제거`나 `조건부 트리거`를 이용해서 다시 돌려보고 싶을때 사용함.

즉 방금 내가 수정한 조건들이 어떻게 적용되는지 볼 수 있음.

---

### 4. 프리셋 관리

<img width="384" height="253" alt="image" src="https://github.com/user-attachments/assets/5e27bafc-9039-4e62-914a-8579bd6f83f3" />


말 그대로 프리셋을 저장할 수 있음. 종류는 `긍정적`, `부정적`, `선행`, `후행`, `캐릭터`, `설정` 총 6가지

<br />

<img width="248" height="369" alt="image" src="https://github.com/user-attachments/assets/c79c10e8-444f-43e4-8709-bb1ac33a69ae" />


오른쪽 위 저장을 누르면 이렇게 프리셋 이름과 무엇을 저장할지 나오고 

각각 `긍정적`, `선행`, `캐릭터`만 저장한 경우 개별 탭에 표시가 됨. 그 외에는 전부 기타 탭

<br />

<img width="298" height="501" alt="image" src="https://github.com/user-attachments/assets/7930aa85-834b-4d38-ab07-eb5454622c5d" />


저장된 프리셋을 누르면 이런 화면이 나오고 위에 그림이 있는 칸을 누르면 미리보기 이미지를 지정할 수 있음

<br />

<img width="296" height="306" alt="image" src="https://github.com/user-attachments/assets/4f8b55bc-3241-457c-823d-cb272b21b8b7" />
<img width="252" height="241" alt="image" src="https://github.com/user-attachments/assets/3d3e0e57-47a5-4b2b-96a3-2a487016df3f" />


기타 탭에 있는 프리셋은 이렇게 나오고 해당하는 항목을 누르면 펼칠 수 있음. 

<br />

<img width="379" height="76" alt="image" src="https://github.com/user-attachments/assets/853f46b0-0915-43ce-b3c1-5cc8e5e7aae8" />

불러올때는 각각 `복사`와 `적용` 2가지를 쓰면 되는데 

`복사`는 클립보드에 프롬프트를 복사해주고

`적용`은 해당하는 프롬프트 칸에 프리셋에 저장된 프롬프트를 바로 넣어줌

단, `복사`는 시스템상 한 종류만 복사 가능함. 어쩔 수 업슴...

---

### 5. 랜덤 잠금

<img width="379" height="50" alt="image" src="https://github.com/user-attachments/assets/3f459a74-5644-445e-96fc-772510cb46ef" />


이걸 체크하면 `다음 프롬프트` 버튼이 눌러지지 않음

만약 내가 수동으로 `긍정적 프롬프트`에 입력을 하고 있는데

실수로 `다음 프롬프트` 눌러서 없어져버리면 화가나게 되는데 그럴때 사용하면 됨.

---

### 6. 자동 저장

<img width="382" height="49" alt="image" src="https://github.com/user-attachments/assets/2c746784-1c79-4c31-9453-89afb0b4e6fe" />


기본적으로 체크되어있는데 체크를 풀게되면 

`히스토리` 목록에만 올라가고 실제 그림은 저장되지 않음.

체크를 하면 생성이 완료될때마다 자동으로 지정된 폴더에 저장됨 (기본 설정은 Download\DNaiApp\날짜_시간)

---

### 7. 연속 생성 기능

<img width="223" height="55" alt="image" src="https://github.com/user-attachments/assets/4a4bb56b-47ea-480e-a092-99cdf64c363f" />


네모를 누르면 `1` > `2` > `3` > `4` > `∞(무한)` 순으로 바뀌고 이미지 생성을 누르면 옆에 남은 숫자가 나옴

네모를 꾹 길게 누르면 임의의 횟수를 지정해서 넣을 수 있고 범위는 `1~999` 까지임

<br />

<img width="221" height="47" alt="image" src="https://github.com/user-attachments/assets/2497e004-461e-46a4-91f1-ed8cc7d4d864" />


만약 연속으로 생성 중에 멈추고 싶을때는 `생성중(n)...` 으로 변한 버튼을 누르면 뒤에 숫자가 사라지면서 추가 생성을 취소함

---

### 8. Vibe Transfer 및 Character Reference 

<img width="304" height="442" alt="image" src="https://github.com/user-attachments/assets/a7dfd0f5-8e73-4cf9-b595-e1db33777c3f" />

<br />

팔레트 모양을 누르면 해당 기능을 사용할 수 있음. (적용중이라면 팔레트가 보라색이 됨)

<br />

`Vibe Transfer`는 그림체를 얼마나 적용할지 정하는 `Reference Strength`(이하 강도)와 

구도, 세부묘사를 얼마나 적용할지 정하는 `Information Extracted`(이하 정보량)이 있음

사실 이게 정확한지 아닌지는 공식에서도 조금 애매하게 말한 구석이 있어서 그냥 올린 이미지의 그림체를 비슷하게 적용할 수 있다. 정도로 보면 됨. 

로컬에서 쓰는 분위기 or 그림체 로라와 유사한느낌?

<br />

<img width="306" height="441" alt="image" src="https://github.com/user-attachments/assets/fd4bd752-f50a-45d0-bb17-a3cc6be72608" />


`Character Reference`는 Vibe와 비슷하지만 캐릭터에 중점을 둔 기능으로 

캐릭터의 묘사를 얼마나 적용할지 정하는 `Strength`(이하 강도)와 해당 캐릭터 이미지를 얼마나 충실하게 적용할지 정하는 `Fidelity`(이하 충실도)가 있음

사실 이것도 Vibe처럼 좀 애매한 구석이 있는데 아무튼 로컬에서 쓰는 캐릭터 로라와 비슷한 기능을 함.

근데 최근에 뭐 업데이트로 적용이 이상하게 된다는 말이 있으니 주의


<br />

`Vibe Transfer`는 내보내기, 불러오기로 내가 적용한 파일을 다른곳에 옮기거나 백업할 수 있음. 다른 사람의 Vibe를 가져오는 것도 가능

한번 적용에 각각 2 Anals를 사용하지만 한 번 이미지를 생성하면 적용된 Vibe를 변경하지 않는 한 추가적인 Anals 소모 없이 계속 적용이 가능함.


`Character Reference`는 내보내기, 불러오기 같은 기능도 없고

한번 적용에 5 Anals를 사용하는데 이미지 생성을 할 때마다 계속 5 Anals가 소모됨. 서버였나 연산에 부담이된다나 뭐라나

방심하다간 어느세 잔뜩 써버릴 수 있으니 주의해야됨.

---
---

<a id="프롬프트-탭-설명---2"></a>
## 📝 프롬프트 탭 설명 - 2

<img width="371" height="774" alt="image" src="https://github.com/user-attachments/assets/d92181c8-0077-4e1b-be0e-c235c48a666b" />

`긍정적 프롬프트`, `선행 프롬프트`, `후행 프롬프트`, `부정적 프롬프트` 는 무엇인지 다 알거라 생각하지만 일단 간단히 설명하면

<br />

실제로 NovelAi로 이미지 생성을 요청할때

`선행` + `긍정적` + `후행` 순으로 조립되서 생성 요청을 보냄.

<br />

`선행`이나 `후행`에는 작가명이나 디테일처럼 어느정도 고정시키고 싶은 프롬프트들을 넣으면 되고

`긍정적`에는 내가 실제로 생성할 이미지에 대한 프롬프트들을 넣으면 됨.

`부정적`은 어지간하면 안바뀔거라 생각해서 아래에 두었음.

---

### 각 프롬프트 축소 및 이동

<img width="366" height="350" alt="image" src="https://github.com/user-attachments/assets/94ee2084-b352-43c9-abda-7240ae71db48" />


각각 프롬프트 이름(`선행 프롬프트`, `후행 프롬프트` 등등)을 누르면 스크린샷처럼 작아짐.

그리고 이렇게 작아진 프롬프트 창은 오른쪽에 `=`가 생기는데 이걸 누른채로 움직이면 

<br />

<img width="361" height="365" alt="image" src="https://github.com/user-attachments/assets/d8718449-0fab-443f-b65b-e9eb636a66ca" />


이런식으로 위치를 바꿀 수 있음. 

`부정적 프롬프트`처럼 이미 입력이 끝났고 자주 변경할 필요가 없는 항목들을 맨 아래로 치워버릴때 쓰기 편함

---

### 태그 제거

<img width="368" height="113" alt="image" src="https://github.com/user-attachments/assets/60eed702-ed86-4277-8940-d6c33349d5a0" />


이 기능은 검색된 프롬프트를 불러올 때 특정한 프롬프트 종류들을 자동으로 제거해줌

<img width="205" height="43" alt="image" src="https://github.com/user-attachments/assets/10c4395d-17f6-439c-9dc0-adb4f8482325" />

이 2가지 버튼을 누를때 작동함

<br />

- `특징 제거` = 캐릭터 특징들을 제거함. 머리카락 관련이라던가 눈 색 등등을 자동으로 지움
  
  -> 주로 특정 캐릭터를 뽑고 싶을 때 사용함
  
- `의상 제거` = 옷과 관련된 프롬프트들을 제거함. skirt pull 같은 기능적인 프롬프트도 다 지워짐
  
  -> 특정 의상을 계속 입히고 싶을 때 사용함
  
- `색상 제거` = 색깔이 들어간 모든 프롬프트를 지움. 옷이라던가 배경도 전부 포함됨
  
  -> 이건 정확히 어떨 때 쓰는지 모르겠음... 필요할때가 있을듯...

---

### 개별 제거 프롬프트

<img width="363" height="99" alt="image" src="https://github.com/user-attachments/assets/e0a7d657-2cb3-40a9-b08e-0d6aef63d767" />


내가 지우고 싶은 특정 프롬프트를 자동으로 지울 때 쓰는 기능임.

위에 있는 `태그 제거`랑 동일한 타이밍에서 작동함.(주로 랜덤 프롬프트를 불러올 때)

<br />

사용 방법은 프롬프트를 검색할때랑 마찬가지로

| 입력 | 결과 |
| :--- | :--- |
| `skirt` | 정확히 skirt인 프롬프트를 제거 |
| `*skirt` | 맨뒤가 skirt로 끝나는 프롬프트를 제거 |
| `skirt*` | 맨앞이 skirt로 시작하는 프롬프트를 제거 |
| `*skirt*` | 아무튼 skirt가 포함된 모든 프롬프트를 제거 |

이고 난 주로 스크린샷처럼 `censor`가 들어간 애들을 자동으로 지워서 모자이크를 없애는 식으로 씀

---

### 조건부 트리거 
<details>
<summary>볼사람만 보셈</summary>
  
조건부는 최대한 NAIA랑 비슷하게 했으나(감사합니다) 조금 다름
  
줄바꿈이 나올 때 까지를 전부 인식하고 예문을 몇개 적어서 이해하기 쉽게 하겠음

| 예시 | 설명 |
| :--- | :--- |
| `(cat):cat = dog` | cat이 있다면 cat을 dog로 바꿔라 |
| `(cat*):cat = dog` | 앞에 cat으로 시작하는 프롬프트가 있다면 cat을 dog로 바꿔라 (*cat으로 바꾸면 cat으로 끝나는 프롬프트) |
| `(cat*):cat*^dog` | 앞에 cat으로 시작하는 프롬프트가 있다면 cat으로 시작하는 프롬프트들중 cat 부분을 dog로 바꿔라 (cat ears랑 cat tail이 있을때 dog ears랑 dog tail 로 바꾼다던가 할 때 쓰려고, 근데 솔직히 복잡해서 안쓸 것 같음) |
| `(e\|q):prefix=nsfw` | Rating:e 나 Rating:q 가 있으면 긍정적 프롬프트 맨 앞에 nsfw 추가 (suffix 로 맨 뒤도 가능) |
| `(white panties&skirt):suffix=windlift` | white panties 랑 skirt 가 있다면 긍정적 프롬프트 맨 뒤에 windlift 추가 |
| `(sleeping):sleeping = sleeping, 2::closed eyes ::, nightgown` | sleeping 이 있다면 sleeping을 "sleeping, 2::closed eyes ::, nightgown" 로 통째로 바꿈 (맨 뒤 쉼표는 알아서 붙음) |

이정도가 있음. 어차피 `(e|q):suffix=nsfw` 같은거 아니면 쓸사람만 쓰는 기능임

만약 정말 쓰고 싶다면 따로 물어봐줘...

복수 조건을 하고 싶으면 `(A&(B|C)&D)` 같은것도 가능 (A랑 D는 무조건 있어야되고 B랑 C중 최소 하나는 있어야 된다는 조건).

</details>

---

### 상세 환경

<img width="364" height="398" alt="image" src="https://github.com/user-attachments/assets/94618019-8c12-4fcd-8d7e-9a683cf92b2e" />


대부분 기본적인 NovelAi 이미지 생성 설정이랑 같고 몇가지 특이한거만 설명함



<img width="367" height="77" alt="image" src="https://github.com/user-attachments/assets/2a067a73-eb41-41e3-8d35-e685624a528b" />


해상도 옆에 `1.5x`는 체크되어있으면 왼쪽에 정해진 해상도의 1.5배 크기의 이미지를 생성함

이건 아래에 설명할 `해상도 모드`를 바꿔도 적용되고 당연하지만 생성시 Anals를 소모함.

<br />

<img width="213" height="76" alt="image" src="https://github.com/user-attachments/assets/de5dae2f-c616-431b-91be-59d6eb1a0140" />

이런식으로 되어있으면 체크 된거임

<br />

<img width="174" height="172" alt="image" src="https://github.com/user-attachments/assets/ee9b965c-ab44-4ace-9b6d-7ea2cb556dec" />

해상도 모드에는 3가지가 있고

| 해상도 | 설명 |
| :--- | :--- |
| `수동` | 현재 선택되어있는 해상도로 이미지를 생성 |
| `랜덤` | 커스텀 해상도를 제외한 해상도중 임의의 해상도로 생성 |
| `자동` | 랜덤 프롬프트가 만들어질 때 저장된 해상도로 생성 |

`자동` 모드가 햇갈릴텐데 NAIA에도 있는 기능이고 Danbooru에서 프롬프트를 가져올때

그 포스트가 가진 해상도를 64px 기준으로 저장해서 그걸 맞춰서 출력함.

즉 Danbooru에 세로로 긴 이미지가 있고 그 이미지의 프롬프트를 생성시키면

자동으로 768x1344 또는 832x1216 정도의 해상도가 출력된다는 거임.

그냥 생각없이 랜덤프롬프트 돌리면서 할때는 유용할지도

<br />

<img width="199" height="451" alt="image" src="https://github.com/user-attachments/assets/e4b6732d-481d-4cef-9b30-55be43777d0a" />


해상도 선택 맨 아래에는 `직접 입력`이 있음. 이걸 누르면 목록에 없는 해상도를 64px 기준으로 작성 가능함

<br />

<img width="246" height="252" alt="image" src="https://github.com/user-attachments/assets/ff71b825-fcf7-40ec-aeac-cfe0b1157e65" />

이런식으로 창이 나와서 내가 추가하거나 이미 추가된 해상도를 제거할 수 있음.

<br />

<img width="198" height="272" alt="image" src="https://github.com/user-attachments/assets/1d36455a-145f-4620-b2b0-cf08d4eaf2a0" />

추가된 해상도는 이렇게 해상도 목록 맨 아래에 점점 누적되고

이 `커스텀 해상도`는 위의 해상도 모드에 있는 `랜덤`이나 `자동`에 포함되지 않음.

순수하게 내가 직접 조정할때만 쓰는것

이걸로 추가되는 해상도도 3,145,728px를 넘으면 알아서 조절되게 변함.

---

### 이미지 상호작용

<img width="378" height="256" alt="image" src="https://github.com/user-attachments/assets/9ab739c4-34ba-489b-b07d-9535f6a7227b" />

프롬프트탭 맨 위에 생성된 이미지를 꾹 누르면 이런 옵션이 나옴

3가지 다 뭐 딱보면 아는 항목일것이고 3번째껄 누르면

<br />

<img width="263" height="444" alt="image" src="https://github.com/user-attachments/assets/397d42d5-cc6b-462f-aa8f-14208af340ad" />

이렇게 나옴 이것도 그냥 딱 알만한 기능

---
---

<a id="히스토리-탭"></a>
## 🕒 히스토리 탭

<img width="379" height="652" alt="image" src="https://github.com/user-attachments/assets/f8eb760d-b47d-49ca-aad5-6906bd9d730b" />

기본적으로 '리스트 모드'가 표시되고 가장 최근에 생성, 작업된 이미지를 30개 까지 보여줌

그림 옆에 화살표는 그냥 좌/우 옆 이미지로 넘어가는 버튼인데 설정에서 끄기 가능

바로 아래 섬네일을 누르면 바로 해당 이미지를 볼 수 있고 저 섬네일을 꾹 누르면 히스토리에서 삭제 가능함.

위에 그리드를 누르면 화면이 바뀌는데

<br />

<img width="378" height="254" alt="image" src="https://github.com/user-attachments/assets/f25c49ff-8169-4ffd-a27e-bbc7987d2688" />

이런식으로 변하고 각 이미지 우측위 별표를 누르면 북마크 기능, 휴지통을 누르면 전체삭제를 할지 물어보는 버튼이 나옴.

여기서 보이는 불러오기 버튼은 위에 리스트 모드에 불러오기랑 같은 기능이고 아래에서 간단히 설명함

여기서만 가능한건 이미지를 꾹 누르면 일반적인 스마트폰 갤러리 앱 처럼 삭제가 가능함.

<br />

<img width="376" height="255" alt="image" src="https://github.com/user-attachments/assets/39f678e6-e1ba-410f-a89b-ca4545988955" />

바로 이렇게.

---

### 프롬프트 확인

![22](https://github.com/user-attachments/assets/b9ed44bb-8939-4e9e-8acc-a4387913dba7)

을 누르면 4가지 항목이 나오고 각각 이미지가 가진 프롬프트를 보여줌

이게 다임

---

### 이미지 불러오기

스마트폰의 갤러리를 열어서 이미지를 골라 히스토리탭 목록 끝에 추가함

생성한 이미지랑 똑같이 꾹 눌러서 상호작용도 가능하고 프롬프트 확인으로 뭐가 들었나 볼 수도 있음

그리드 모드에 있는 불러오기도 동일하게 히스토리에 추가함

---
---

<a id="img2img-탭"></a>
## 🎨 img2img 탭

<img width="371" height="749" alt="image" src="https://github.com/user-attachments/assets/6c0f8658-408d-4b5f-b44d-36e9337ba644" />

이미지를 꾹 눌러서 나오는 창 중에 '이미지 수정하기(i2i)' 를 누르면 자동으로 이 i2i탭으로 오면서 이미지가 놓여짐

맨위에 3가지 모드가 있고 각각 오른쪽 위에 커다란 버튼으로 적용이 가능함.

각 모드를 간단히 설명하면

<br />

"인페인트"를 누르면 마스킹 씌운 영역에 우리가 아는 그 inpaint기능을 실행함 (바로 윗 스샷)

아래 버튼은 순서대로
* 브러시 (2번 누르면 브러시 크기 변경 및 브러시 색상 변경)
* 지우개 (2번 누르면 지우개 크기 변경 및 전체 지우기)
* 돋보기 (+일때 누르면 확대, 돋보기를 한번 더 터치하면 -로 변경)
* 화면이동 (돋보기로 확대됐을때 사용)
* inpaint strength 수치 조절

<br />

<img width="372" height="702" alt="image" src="https://github.com/user-attachments/assets/52e8f842-7148-498e-80a8-f6b2d6af0120" />

"모자이크"를 누르면 마스킹 씌운 영역에 임의의 모자이크를 적용시킴

아래 버튼중에 인페인트랑 겹치는걸 제외하고 가장 오른쪽 3개만 설명하자면
* 강도 (모자이크를 얼마나 강하게 주는지 정도를 정함)
* 픽셀화 / 블러 / 검정칠 3가지를 변경하는 버튼
* 미리보기 버튼 (잠깐 로딩 후 어떻게 모자이크가 적용되는지 미리 보여줌)

<br />

"업스케일"은 개별적인 버튼은 없지만 지금 i2i탭에 올라온 이미지를 4배 확대해서 저장함

3가지 모두 실행후에 자동으로 "히스토리 탭"으로 가지면서 올라감. 단, 업스케일은 자동으로 폴더에 저장되게 해뒀음. anals 쓴게 아까워서

그리고 아래 프롬프트 보기 버튼을 누르면

<br />

<img width="377" height="554" alt="image" src="https://github.com/user-attachments/assets/e464933d-3cbe-436c-b678-4d24c1282249" />

잘 아는 4가지 프롬프트 창이 나오고 2가지 버튼이 있음

프롬값 가져오기 - 현재 프롬프트 탭에 있는 4가지 프롬프트를 그대로 복사해옴
상세 환경 - 프롬프트탭 맨아래 있는 그 상세환경임. 인페인트에서 적용되길래 여기서도 수정 가능하도록 넣어둠

---
---

<a id="캐릭터-탭"></a>
## 👥 캐릭터 탭

<img width="363" height="787" alt="image" src="https://github.com/user-attachments/assets/644286a7-6514-4ebb-a0ba-3e04c1e5f43b" />

각 숫자 항목에 대해 간단히 설명하면

<br />

1. +로 캐릭터를 추가할 수 있고 보라색인 동그라미를 누르면 회색으로 변하면서 OFF, 다시 누르면 보라색이 되면서 ON 전환을 할 수 있음

2. 캐릭터 이름 바꾸기. 누르면 바꿀 수 있음

3. 이걸 누르면 1에서 ON/OFF되는 기능이랑 동일함. 뭘 눌러도 ON/OFF가 가능함

4. 캐릭터 배치인데 캐릭터가 2명이상 활성화 되어있을때만 적용되고 "위치 초기화"를 누르면 전부 3.3 위치로 가지면서 배치 기능이 자동으로 OFF됨

---
---

<a id="와일드-카드-탭"></a>
## 🃏 와일드 카드 탭

<img width="377" height="470" alt="image" src="https://github.com/user-attachments/assets/bd14c22d-a93a-4e61-8d46-e458f487d818" />

말해서 뭐하겠습니까 "그 기능"

만든 와일드카드 불러오는 방법은 `__와일드카드이름__` 이고 (밑줄 2개) 생성된 와일드카드는 미리보기에 자동으로 지원됨

<br />

각 프롬프트 앞에는 숫자를 넣을 수 있음.

원래 NAIA에서 있던 방식이고 문법은 살짝 다르지만 기능은 동일함.

예시문을 기준으로 하면 전체 합은 450이고 skrit는 약 44%로 뽑히며 pants는 약 11%로 뽑히게 된다는 뜻임

굳이 안쓰고 그냥 프롬프트만 3개 넣으면 각각 33%로 뽑힘

나머진 건드려보면 바로바로 보일거임. 특이사항으로는

<br />

<img width="376" height="307" alt="image" src="https://github.com/user-attachments/assets/69216756-c04a-4aac-9aa8-b2a5f9d58abe" />

이런식으로 프롬프트 작성때처럼 위에 미리보기가 나온다는 것

---
---

<a id="설정-탭"></a>
## ⚙️ 설정 탭

<img width="364" height="729" alt="image" src="https://github.com/user-attachments/assets/29f7d5b4-81aa-4048-8c17-a1b784a33b60" />

위에부터 순서대로 설명하면

*현재 생성된 이미지* - 현재 앱을 켠 상태에서 이미지가 몇개 저장됐는지 알려주는 기능. 왜 넣었는지는 기억이 안남...

<br />

*저장 경로 및 파일 이름* - 말 그대로 저장될 폴더랑 파일의 저장 형식을 정할 수 있음

파일 이름은 연도=`{yy}` 월=`{mm}` 일=`{dd}` 시간=`{time}` 이 규칙이고 나머지는 적는 그대로 추가되서 알기 편할거임

<br />

*생성 시 메세지* - 이미지 생성을 하거나 연속 생성시 화면 아래에 생성됐다고 뜨는데 그걸 꺼줌. 대신 인페인트나 업스케일 같은거 할때는 뜨게 되어있음. 테스트좀 하다가 전부 끌 수 있도록 바꿀지 정할 예정.

<br />

*연속 생성 딜레이* - 이미지 생성시 연속으로 생성하는걸 켰을때 중간에 딜레이를 몇초로 할지 정함. 0초부터 5초까지 0.1단위로 지정 가능

<br />

*좌우 스와이프* - 이걸 켜면 드래그해서 각 탭을 이동할 수 있는데 i2i탭에서 엄청 불편해서 기본적으로 꺼뒀음. 지워도 될듯

<br />

*탭 표시 설정* - 버튼을 터치해서 회색으로 만들면 그 탭이 안보임. 

단, 히스토리 탭을 꺼도 이미지는 저장되고 i2i탭을 꺼도 i2i탭으로 보내기를 하면 탭이 켜지면서 이미지가 올라감

<br />

<img width="369" height="649" alt="image" src="https://github.com/user-attachments/assets/39dd0d6e-87a5-4ec1-b4dc-658c693ab321" />

*설정 백업* - 현재 정해진 모든 설정을 저장(프롬프트, 세팅, 캐릭터, Api 등등 모든 것). 스마트폰 공유 기능을 쓰고있고 내보내기로 불러오기 가능함.

<br />

*NovelAi API, Gelbooru Api* - 이건 맨처음 초기 세팅때 설명했으니 패스

<br />

*기동 시 업데이트 확인* - 이걸 켜두면 앱을 처음 켤때 github에 지금보다 높은 버젼이 나왔는지 확인하고 자동으로 다운받을 수 있게 함.

그 아래 업데이트 확인은 수동으로 체크할때 쓰는건데 자동 확인을 켜뒀으면 큰 의미는 없음

---
---

이 앱에서 필요한 권한은 

- 백그라운드 실행 (이미지 생성중 앱을 내려도 생성되고 저장될 수 있게)
- 폴더 접근 권한 (이미지 저장 및 불러올때 해당 폴더에 대한 권한)

정도만 있음. 개인적으로 좀 민감한 부분이라 몇번이고 최소 권한으로 재설정했으니 걱정 안해도 됨

<br />

추가로 github에 올라가있는 파일들은 버젼 올릴때마다 그대로 복붙하는거라 정 의심스러우면 코드 확인해도 무방함

내가 즐기려고 만든거고 꽤 괜찮게 만들어진김에 다같이 쓰자고 올린거라 누구 해킹하고 그럴 생각 전혀 ㄴ

마지막으로 그럴리 없겠지만 문제 생길 시 삭제하고 건의사항 있으면 아카라이브 홍보글에 댓글 써주셈
