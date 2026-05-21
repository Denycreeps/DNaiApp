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
* [와일드카드 탭](#와일드-카드-탭)
* [설정 탭](#설정-탭)

---

## ⚙️ 초기 설정 방법

<img width="379" height="768" alt="image" src="https://github.com/user-attachments/assets/9a2c9a49-97b5-4b2c-b475-1d940c9371a0" />


처음 어플을 켠 뒤 "설정"탭으로 가서 아래로 내리면 NovelAi Api랑 Gelbooru Api가 필요하다고 나옴

Gelbooru Api는 랜덤 프롬프트 검색기능을 사용안하면 필요 없지만 이 어플을 쓰는 목적이라 가급적 추천함

Danbooru에서만 검색하는거보다 훨씬 효율적인걸로 판명되서 Gelbooru Api를 쓰는건데

다른 앱이나 프로그램에서 쓰는 방식(Danbooru 만으로 api없이 검색)으로도 잘 돌아가는 방법을 찾으면 그땐 없어질 것 같음

근데 만들면서 계속 써봤지만 지금도 충분히 속도도 나오고 불만 없는듯

<br />

<img width="456" height="349" alt="003" src="https://github.com/user-attachments/assets/c6e21a76-1d09-434c-a743-3cd92cd46f6c" />
<img width="717" height="541" alt="004" src="https://github.com/user-attachments/assets/fc30cb73-561d-43be-8aea-e60727f1dce8" />


NovelAi Api는 모두가 아는 그 방법을 쓰면 얻을 수 있고

<br />

<img width="529" height="182" alt="005" src="https://github.com/user-attachments/assets/6c99216d-c55e-49ef-9b2d-e6a30e459a31" />


Gelbooru 토큰은 겔부루 사이트에서 My Account 를 누르고

<br />

<img width="424" height="631" alt="006" src="https://github.com/user-attachments/assets/1d62747d-280a-41f0-a479-3c639176bc5e" />


여기서 맨 아래 Option을 누르면 되는데

<img width="420" height="297" alt="image" src="https://github.com/user-attachments/assets/faf74e6b-bf9a-4d99-ab84-a21348c25400" />
<img width="447" height="313" alt="image" src="https://github.com/user-attachments/assets/8b14c12a-ff16-44a7-be31-44160d6f75a1" />


아이디가 없으면 이렇게 뜨니까 빨간 동그라미를 따라가서 새로 가입하면 됨

<br />

<img width="332" height="205" alt="007" src="https://github.com/user-attachments/assets/064c13e4-6149-4584-833d-89c38e744c96" />


Option 맨 아래에 Api 토큰이 있는데 형식은 `&api_key="내 API 키"&user_id="내 ID 숫자"` 로 되어 있고 이거 전체를 그대로 복사해서 넣으면 됨

NovelAi Api는 "토큰 저장 및 연결"을 누르면 되고 Gelbooru는 그냥 넣으면 알아서 인식함

여기까지 했으면 이제 바로 사용 가능

---
---

## 📝 프롬프트 탭 설명 - 1

<img width="379" height="674" alt="image" src="https://github.com/user-attachments/assets/9c47f869-bd85-4da9-b9ea-f53d499d8adf" />


다른건 딱 보면 알것이고 설명이 필요한 부분만 말하자면

---

### 1. 톱니바퀴(검색창 열고 닫기)
<img width="376" height="199" alt="image" src="https://github.com/user-attachments/assets/2252f263-0d5f-459c-891a-c70b8f871c4f" />


열면 스크린샷처럼 화면이 나옴. NAIA를 매우 강하게 배꼈습니다. 감사합니다.


윗칸은 찾을 프롬프트, 아래칸은 제거할 프롬프트임

아래 E, Q, S, G 는 생각하는 그것이고

검색할때 `*`을 붙인 곳에 따라 범위가 바뀌고 윗칸 아래칸에서 모두 사용 가능함.

| 입력 예시 | 검색 방식 |
| :--- | :--- |
| `skirt` | skirt 프롬프트 검색 |
| `*skirt` | skirt로 끝나는 프롬프트 |
| `skirt*` | skirt로 시작하는 프롬프트 |

<img width="369" height="255" alt="image" src="https://github.com/user-attachments/assets/a2c636e5-a2f6-46d5-9cb3-a77798695046" />


검색창에는 단어를 입력하면 Danbooru 기준 가장 사용량이 많은 순으로 입력한 글자로 시작하는 태그가 미리 표시됨

터치하면 그대로 쉼표까지 입력되고 저 창을 드래그하면 아래로 목록을 내릴 수 있음

Danbooru 기준 사용량 100이상은 모두 넣어뒀으니 애지간한 프롬프트는 다 있을 것


만약 검색량을 넘게되면 그 뒤로는 단어앞에 `*`을 붙여서 검색한 단어를 포함한 또는 단어로 끝나는 프롬프트들을 표시해줌

그리고 띄어쓰기 하면 눈치있게 잘 찾아주게 해뒀음 (pla ski = plaid skirt가 나옴)

다 정하고 "검색" 버튼을 누르면 "검색 : n" 이랑 "남음 : n" 을 표시해줌

---

### 2. 다음 프롬프트

이걸 누르면 위에 톱니바퀴를 이용해 검색한 목록(랜덤으로 섞임)에서 저장된 다음 순서의 프롬프트를 가져와서 "긍정적 프롬프트"에 넣어줌

아래에서 다시 후술하겠지만 "개별 제거"나 "조건부 트리거"는 이 과정에서 정제됨

---

### 3. 현재 프롬프트 다시 불러오기

근데 목록에서 불러왔는데 조금 전에 말한 "개별 제거"나 "조건부 트리거"를 수정해서 다시 불러오고 싶을 수 있잖음?

그럴때 이걸 누르면 방금 불러왔던 목록을 다시 한번 불러옴

즉 내가 수정한게 어떻게 적용되는지 볼 수 있음

---

### 4. 프리셋 관리
<img width="384" height="253" alt="image" src="https://github.com/user-attachments/assets/5e27bafc-9039-4e62-914a-8579bd6f83f3" />


말 그대로 프리셋을 저장할 수 있음. 종류는 긍정적, 부정적, 선행, 후행, 캐릭터, 설정 총 6가지

<img width="248" height="369" alt="image" src="https://github.com/user-attachments/assets/c79c10e8-444f-43e4-8709-bb1ac33a69ae" />


오른쪽 위 저장을 누르면 이렇게 프리셋 이름과 무엇을 저장할지 나오고 긍정적, 선행, 캐릭터만 저장한 경우 개별 탭에 표시가 됨. 그 외에는 전부 기타 탭

<img width="298" height="501" alt="image" src="https://github.com/user-attachments/assets/7930aa85-834b-4d38-ab07-eb5454622c5d" />


저장된 프리셋을 누르면 이런 화면이 나오고 위에 그림이 있는 칸을 누르면 미리보기 이미지를 지정할 수 있음

<img width="296" height="306" alt="image" src="https://github.com/user-attachments/assets/4f8b55bc-3241-457c-823d-cb272b21b8b7" />
<img width="252" height="241" alt="image" src="https://github.com/user-attachments/assets/3d3e0e57-47a5-4b2b-96a3-2a487016df3f" />


기타 탭에 있는 프리셋은 이렇게 나오고 해당하는 항목을 누르면 펼칠 수 있음. 

앞에 3개는 복 복사하거나 적용할때 그 프롬프트만 나오지만 기타 탭에 있는 프리셋을 불러올땐 내가 원하는 것만 가져올 수 있게 해뒀음. 

단, 복사는 시스템상 한 종류만 복사 가능함. 어쩔 수 업슴...

---

### 5. 랜덤 잠금

이거 하면 "다음 프롬프트" 버튼이 안눌림, 왜 있냐고?

수동으로 프롬프트 작성하면서 뽑고 싶은데 실수로 "다음 프롬프트" 누르면 열받아서

---

### 6. 자동 저장

이게 꺼지면 "히스토리" 목록에만 올라가고 실제로 파일이 저장되지 않음

체크되면 생성 완료될때마다 자동으로 지정된 폴더에 저장됨 (기본 설정은 Download\DNaiApp\날짜_시간 폴더)

---

### 7. 연속 생성 기능

<img width="223" height="55" alt="image" src="https://github.com/user-attachments/assets/4a4bb56b-47ea-480e-a092-99cdf64c363f" />


네모를 누르면 1 2 3 4 ∞ 순으로 바뀌고 이미지 생성을 누르면 옆에 남은 숫자가 나옴

<img width="222" height="54" alt="image" src="https://github.com/user-attachments/assets/6fd963e4-b25d-4be4-8008-dc9db6be4742" />


만약 중간에 생성을 멈추고 싶을때는 "생성중(n)..." 으로 변한 버튼을 누르면 뒤에 숫자가 사라지면서 추가 생성을 취소함

---

## 📝 프롬프트 탭 설명 - 2

<img width="378" height="754" alt="p002" src="https://github.com/user-attachments/assets/101a4d80-5c3a-4fb0-84ce-5f1526d7d498" />

사실 뭐 보면 다 아는거고 특이한 것만 적자면

### 개별 제거 프롬프트
"다음 프롬프트"를 눌러서 검색된 프롬프트 목록을 불러올때 여기 있는 애들을 자동으로 지워줌

굳이 문법이 있다면
| 입력 | 결과 |
| :--- | :--- |
| `skirt` | 정확히 skirt인 프롬프트를 제거 |
| `*skirt` | 맨뒤가 skirt로 끝나는 프롬프트를 제거 |
| `skirt*` | 맨앞이 skirt로 시작하는 프롬프트를 제거 |
| `*skirt *` | 아무튼 skirt가 포함된 모든 프롬프트를 제거 (띄어쓰기는 필요 없음) |

쉬움

### 조건부 트리거 
<details>
<summary>볼사람만 보셈</summary>
조건부는 최대한 NAIA랑 비슷하게 했으나(감사합니다) 조금 다름
줄바꿈이 나올때까지를 전부 인식하고 예문을 몇개 적어서 이해하기 쉽게 하겠음

| 예시 | 설명 |
| :--- | :--- |
| `(cat):cat = dog` | cat이 있다면 cat을 dog로 바꿔라 |
| `(cat*):cat = dog` | 앞에 cat으로 시작하는 프롬프트가 있다면 cat을 dog로 바꿔라 (*cat으로 바꾸면 cat으로 끝나는 프롬프트) |
| `(cat*):cat*^dog` | 앞에 cat으로 시작하는 프롬프트가 있다면 cat으로 시작하는 프롬프트들중 cat 부분을 dog로 바꿔라 (cat ears랑 cat tail이 있을때 dog ears랑 dog tail 로 바꾼다던가 할 때 쓰려고, 근데 솔직히 복잡해서 안쓸 것 같음) |
| `(e\|q):prefix=nsfw` | Rating:e 나 Rating:q 가 있으면 긍정적 프롬프트 맨 앞에 nsfw 추가 (suffix 로 맨 뒤도 가능) |
| `(white panties&skirt):suffix=windlift` | white panties 랑 skirt 가 있다면 긍정적 프롬프트 맨 뒤에 windlift 추가 |
| `(sleeping):sleeping = sleeping, 2::closed eyes ::, nightgown` | sleeping 이 있다면 sleeping을 "sleeping, 2::closed eyes ::, nightgown" 로 통째로 바꿈 (맨 뒤 쉼표는 알아서 붙음) |

이정도가 있음. 어차피 `(e|q):suffix=nsfw` 같은거 아니면 쓸사람만 쓰는 기능임
</details>

### 상세 환경
<img width="375" height="431" alt="image" src="https://github.com/user-attachments/assets/c1965fdf-6480-4c3c-9074-8cefc4ab3bf4" />

잘 아는 그거임

### 이미지 상호작용
<img width="378" height="256" alt="image" src="https://github.com/user-attachments/assets/9ab739c4-34ba-489b-b07d-9535f6a7227b" />

화면에 있는 생성된 큰 이미지를 꾹 누르면 이런 옵션이 나옴
3가지 다 뭐 딱보면 아는 항목일것이고 3번째껄 누르면

<img width="263" height="444" alt="image" src="https://github.com/user-attachments/assets/397d42d5-cc6b-462f-aa8f-14208af340ad" />

이렇게 나옴 이것도 그냥 딱 알만한 기능

---

## 🕒 히스토리 탭

<img width="379" height="664" alt="image" src="https://github.com/user-attachments/assets/4a2cbd14-ed5b-4c47-b4cc-2f7448c5e27f" />

그냥 보면 알만한 것들 뿐이지만 (1)에 굳이 화살표가 있는 이유는 바로 아래 (2)섬네일 미리보기가 만들어지기 전에 옆 이미지를 보기위해 만들어진거뿐임
참고로 (2)섬네일을 꾹 누르면 지우기가 뜹니다.

### 프롬프트 확인
![22](https://github.com/user-attachments/assets/b9ed44bb-8939-4e9e-8acc-a4387913dba7)

을 누르면 4가지 항목이 나오고 각각 이미지가 가진 프롬프트를 보여줌
이게 다임

### 이미지 불러오기
스마트폰의 갤러리를 열어서 이미지를 골라 히스토리탭 목록 끝에 추가함
생성한 이미지랑 똑같이 꾹 눌러서 상호작용도 가능하고 프롬프트 확인으로 뭐가 들었나 볼 수도 있음

---

## 🎨 img2img 탭

<img width="380" height="630" alt="image" src="https://github.com/user-attachments/assets/cbb45243-d957-4ccc-a533-2481e6de83f1" />

이미지를 꾹 눌러서 나오는 창 중에 '이미지 수정하기(i2i)' 를 누르면 자동으로 이 i2i탭으로 오면서 이미지가 놓여짐

맨 위 왼쪽에 "인페인트"을 누르면 마스킹 씌운 영역이 프롬프트따라 우리가 아는 그 inpaint기능을 실행하고
맨 위 오른쪽에 "업스케일"을 누르면 지금 i2i탭에 올라온 이미지를 4배 확대해서 저장함
둘 다 실행후에 자동으로 "히스토리 탭"으로 가지면서 올라감. 단, 업스케일은 자동으로 폴더에 저장되게 해뒀음. anals 쓴게 아까워서

아래 버튼은 순서대로
* 브러시(누르면 크기 변경 가능)
* 브러시 색 바꾸기
* 지우개(누르면 크기 변경 가능, 마스크 전체 지우기 있음)
* 돋보기(+일때 누르면 확대, 돋보기를 한번 더 터치하면 -로)
* 화면이동(돋보기로 확대됐을때 사용)
* inpaint strength 수치 조절

전부 인페인트를 하려고 만든 버튼이고 그 아래로 가면

<img width="379" height="506" alt="image" src="https://github.com/user-attachments/assets/26a4ae26-9890-4b41-ae44-fd92b957074c" />

4개는 딱보면 알거고 상세환경도 보면 알꺼고 "프롬값 가져오기"를 하면 지금 "프롬프트 탭"에 있는 4가지 프롬프트를 "i2i탭"에 적용함

아 여기서 **중요한 포인트**가 있는데

<img width="380" height="313" alt="image" src="https://github.com/user-attachments/assets/3709a0e4-1110-4961-b4a6-1747b5605b63" />

빨강색 영역을 터치하면 드래그로 스크롤이 안되고 노란색 영역을 한번 터치해야 드래그로 스크롤이 됨
이걸 안하니까 마스크 그리는 중간에 자꾸 스크롤되길래 ai랑 둘이 한참 뭐가좋을지 토론하다가 결국 이렇게 만들어졌음. 
살짝 불편한감은 있는데 양해바랍니다 ㅎ

---

## 👥 캐릭터 탭

<img width="371" height="578" alt="image" src="https://github.com/user-attachments/assets/5460c966-977d-4567-8f36-e718f3116260" />

아마 처음 켰으면 위에 생성했던 이미지가 대문짝만하게 있을 텐데 설정에 끄는곳이 있음 자세한건 설정 탭 설명에서

일단 (1)은 말 그대로 캐릭터 갯수고 +를 누르면 계속 추가됨
이쪽 UI는 NaiApp을 배꼈습니다. 매번 감사합니다.

그리고 (2)눈깔모양을 누르면 왼쪽 (1)이 보라색/회색 되면서 ON/OFF가 됨
캐릭터를 여러개 만들어두고 껐다켰다로 조절하면 이미지 뽑을때 편하더라고. 이건 NAIA 선생님에게 배웠습니다.

마지막 (3)은 다들 아는 캐릭터 배치. ai한테 시켰는지 기억안나는데 캐릭터 1개면 아마 어딜 옮겨도 의미없을것

---

## 🃏 와일드 카드 탭

<img width="377" height="470" alt="image" src="https://github.com/user-attachments/assets/bd14c22d-a93a-4e61-8d46-e458f487d818" />

말해서 뭐하겠습니까 "그 기능"

NAIA에서 있던 방식중 하나로 문법은 다르지만 예시문을 기준으로 전체 합은 450이고 skrit는 약 44%로 뽑히며 pants는 약 11%로 뽑히게 된다는 뜻
굳이 안쓰고 그냥 프롬프트만 3개 넣으면 각각 33%로 뽑힘

나머진 건드려보면 바로바로 보일거임. 특이사항으로는

<img width="376" height="307" alt="image" src="https://github.com/user-attachments/assets/69216756-c04a-4aac-9aa8-b2a5f9d58abe" />

이런식으로 적는중에 위에 프롬프트 작성때처럼 미리보기가 나온다는 것

---

## ⚙️ 설정 탭

<img width="374" height="746" alt="image" src="https://github.com/user-attachments/assets/899e66d2-6d33-42ce-993a-7573cbaeb067" />

대부분 보면 아는거라 특이한거만 적으면

(1)은 이번에 뽑은(정확힌 저장한) 이미지 갯수. 그냥 있어야될 것 같아서...

(2)는 끄면 "캐릭터 탭"이랑 "와일드카드 탭" 위에 큰 이미지가 안보이게됨

저장 경로는 옆에 버튼누르면 어디 저장할지 뜨고 수동으로도 작성 가능함

파일 이름은 연도=`{yy}` 월=`{mm}` 일=`{dd}` 시간=`{time}` 번호=`{count}` 가 규칙이고 나머지는 적는 그대로 이름으로 적혀서 알기 편할거임
여기서 번호가 뭐냐면 (1) 숫자인데 솔직히 필요 없는데 지우기도 굳이라서 놔둔 기능

API토큰은 오직 로컬에 저장되며 소스를 보면 아시겠지만 어디로 전송하고 그런건 없슴니다. 필요도 없고
그리고 그럴리 없겠지싶지만 문제 생기면 삭제됨니다.
