# DNaiApp

NAIA랑 Prombot 그리고 NaiApp 이 3가지를 적당히 배낀 파쿠리 어플임

프롬봇이 사라져서 스마트폰으로 이미지 뽑기가 불편한 나머지 Ai를 고문하여 직접 만들었습니다.

사실상 99.9% 정도를 Claude와 Gemini가 만든 말하자면 Ai가 만든 Ai 이미지 만들기를 돕는 어플리케이션

미래는 Ai가 책임진다.
<br /><br />

[초기 설정 방법](https://github.com/Denycreeps/DNaiApp#%EC%B4%88%EA%B8%B0-%EC%84%A4%EC%A0%95-%EB%B0%A9%EB%B2%95)
[프롬프트 탭 설명 1](https://github.com/Denycreeps/DNaiApp#%ED%94%84%EB%A1%AC%ED%94%84%ED%8A%B8-%ED%83%AD-%EC%84%A4%EB%AA%85---1)
[프롬프트 탭 설명 2](https://github.com/Denycreeps/DNaiApp#%ED%94%84%EB%A1%AC%ED%94%84%ED%8A%B8-%ED%83%AD-%EC%84%A4%EB%AA%85---2)

<br /><br />
---

# 초기 설정 방법

<img width="384" height="196" alt="001" src="https://github.com/user-attachments/assets/f679de79-c409-4b4d-8050-3e7f97ed029a" />

처음 어플을 켠 뒤 "설정"탭으로 가면 Nai 연동이 필요하다고 나옴
<br />
<br />

<img width="374" height="371" alt="002" src="https://github.com/user-attachments/assets/3e3c6435-aa43-406a-b95d-06a5582303db" />

아래로 내리면 Nai 토큰과 Gelbooru 토큰을 달라고 함

Gelbooru 토큰이 필요한 이유는 아무리 Ai랑 머리싸매도 Gelbooru에서 검색을 하는게 더 검색이 용이하다는 결론이 났기 때문인데

다른 앱이나 프로그램에서 쓰는 방식(Danbooru 만으로 api없이 검색)으로도 잘 돌아가는 방법을 찾으면 그땐 없어질 것 같음

근데 만들면서 계속 써봤지만 지금도 충분히 속도도 나오고 불만 없는듯
<br />
<br />

<img width="456" height="349" alt="003" src="https://github.com/user-attachments/assets/c6e21a76-1d09-434c-a743-3cd92cd46f6c" />
<img width="717" height="541" alt="004" src="https://github.com/user-attachments/assets/fc30cb73-561d-43be-8aea-e60727f1dce8" />

Nai 토큰은 모두가 아는 그 방법을 쓰면 얻을 수 있고
<br />
<br />

<img width="529" height="182" alt="005" src="https://github.com/user-attachments/assets/6c99216d-c55e-49ef-9b2d-e6a30e459a31" />

Gelbooru 토큰은 겔부루 사이트에서 My Account 를 누르고
<br />
<br />

<img width="424" height="631" alt="006" src="https://github.com/user-attachments/assets/1d62747d-280a-41f0-a479-3c639176bc5e" />

여기서 맨 아래 Option을 누르면 되는데

아이디가 없으면 맨 위에가 Login으로 되어있고 누르면 가입하는 화면으로 갈 수 있음
<br />
<br />

<img width="332" height="205" alt="007" src="https://github.com/user-attachments/assets/064c13e4-6149-4584-833d-89c38e744c96" />

Option 맨 아래에 Api 토큰이 있는데 형식은

&api_key="내 API 키"&user_id="내 ID 숫자"

로 되어 있고 이거 전체를 그대로 복사해서 넣으면 됨
<br />
<br />

Nai 토큰은 "저장 및 연결"을 누르면 되고 Gelbooru는 그냥 넣으면 알아서 인식함

여기까지 했으면 이제 바로 사용 가능
<br />
<br />

---
---

# 프롬프트 탭 설명 - 1

<img width="381" height="657" alt="p001" src="https://github.com/user-attachments/assets/4213eb00-7f65-4df9-bffa-d434864a2812" />

다른건 딱 보면 알것이고 설명이 필요한 부분만 말하자면
<br />
<br />

---

## 1. 톱니바퀴(검색창 열고 닫기).

<img width="375" height="246" alt="p001_" src="https://github.com/user-attachments/assets/403cbcbf-5953-4cc3-9bcd-2eb1329e9ce3" />

열면 스크린샷처럼 화면이 나옴. NAIA를 매우 강하게 배꼈습니다. 감사합니다.

아래 E, Q, S, G 는 생각하는 그것이고

검색은 NAIA에서 *이나 !가 없고 단어 그대로만 검색한다고 생각하면 됨

'ex) skirt가 포함된 모든 프롬프트를 검색' 같은 기능은 아직 안만들었음... 사용량 거의다써서...
<br />
<br />

<img width="369" height="255" alt="image" src="https://github.com/user-attachments/assets/a2c636e5-a2f6-46d5-9cb3-a77798695046" />

검색창에는 단어를 입력하면 Danbooru 기준 가장 사용량이 많은 순으로 입력한 글자로 시작하는 태그가 미리 표시됨

터치하면 그대로 쉼표까지 입력되고 저 창을 드래그하면 아래로 목록을 내릴 수 있음

Danbooru 기준 사용량 100이상은 모두 넣어뒀으니 애지간한 프롬프트는 다 있을 것

그리고 "검색" 버튼을 누르면 지가 찾아서 "검색 : n" 이랑 "남음 : n" 을 표시해줌
<br />
<br />

---

## 2. 다음 프롬프트

이걸 누르면 위에 톱니바퀴를 이용해 검색한 목록(랜덤으로 섞임)에서

저장된 다음 순서의 프롬프트를 가져와서 "긍정적 프롬프트"에 넣어줌

아래에서 다시 후술하겠지만 "개별 제거"나 "조건부 트리거"는 이 과정에서 정제됨
<br />
<br />

---

## 3. 현재 프롬프트 다시 불러오기

근데 목록에서 불러왔는데 조금 전에 말한 

"개별 제거"나 "조건부 트리거"를 수정해서 다시 불러오고 싶을 수 있잖음?

그럴때 이걸 누르면 방금 불러왔던 목록을 다시 한번 불러옴

즉 내가 수정한게 어떻게 적용되는지 볼 수 있음
<br />
<br />

---

## 4. 프리셋 관리

<img width="383" height="282" alt="image" src="https://github.com/user-attachments/assets/8ae6806a-4608-41df-a17a-8f3f035b143e" />

말 그대로 현재 저장된 프롬프트(긍정적, 선행, 후행, 부정적)를 저장하는 프리셋 기능임

누르면 위 스샷처럼 나오고 각 목록을 터치함으로써 현재 프리셋에 저장된 프롬프트를 간단히 볼 수 있음

<img width="378" height="497" alt="image" src="https://github.com/user-attachments/assets/5771c8c1-bf30-4206-99a7-df59df207a05" />

바로 이렇게
<br />
<br />

---

## 5. 랜덤 잠금

이거 하면 "다음 프롬프트" 버튼이 안눌림, 왜 있냐고?

수동으로 프롬프트 작성하면서 뽑고 싶은데 실수로 "다음 프롬프트" 누르면 열받아서
<br />
<br />

---

## 6. 자동 저장

이게 꺼지면 "히스토리" 목록에만 올라가고 실제로 파일이 저장되지 않음

체크되면 생성 완료될때마다 저장됨니다.
<br />

---
---

#  프롬프트 탭 설명 - 2

<img width="378" height="754" alt="p002" src="https://github.com/user-attachments/assets/101a4d80-5c3a-4fb0-84ce-5f1526d7d498" />

사실 뭐 보면 다 아는거고 특이한 것만 적자면
<br />
<br />

---

## 개별 제거 프롬프트

"다음 프롬프트"를 눌러서 검색된 프롬프트 목록을 불러올때 여기 있는 애들을 자동으로 지워줌

굳이 문법이 있다면

- skirt = 정확히 skirt인 프롬프트를 제거
- *skirt = 맨뒤가 skirt로 끝나는 프롬프트를 제거
- skirt* = 맨앞이 skirt로 시작하는 프롬프트를 제거
- *skirt * = 아무튼 skirt가 포함된 모든 프롬프트를 제거 (띄어쓰기는 필요 없음)

정도가 있음, 쉬움
<br />
<br />

---

## 조건부 트리거 

조건부는 최대한 NAIA랑 비슷하게 했으나(감사합니다) 조금 다름

줄바꿈이 나올때까지를 전부 인식하고 예문을 몇개 적어서 이해하기 쉽게 하겠음

- (cat):cat = dog

cat이 있다면 cat을 dog로 바꿔라
<br />
<br />

- (cat*):cat = dog

앞에 cat으로 시작하는 프롬프트가 있다면 cat을 dog로 바꿔라 (*cat으로 바꾸면 cat으로 끝나는 프롬프트)
<br />
<br />

- (cat*):cat*^dog

앞에 cat으로 시작하는 프롬프트가 있다면 cat으로 시작하는 프롬프트들중 cat 부분을 dog로 바꿔라

(cat ears랑 cat tail이 있을때 dog ears랑 dog tail 로 바꾼다던가 할 때 쓰려고, 근데 솔직히 복잡해서 안쓸 것 같음)
<br />
<br />

- (e|q):prefix=nsfw

Rating:e 나 Rating:q 가 있으면 긍정적 프롬프트 맨 앞에 nsfw 추가 (suffix 로 맨 뒤도 가능)
<br />
<br />

- (white panties&skirt):suffix=windlift

white panties 랑 skirt 가 있다면 긍정적 프롬프트 맨 뒤에 windlift 추가
<br />
<br />

- (sleeping):sleeping = sleeping, 2::closed eyes ::, nightgown

sleeping 이 있다면 sleeping을 "sleeping, 2::closed eyes ::, nightgown" 로 통째로 바꿈 (맨 뒤 쉼표는 알아서 붙음)
<br />
<br />
<br />

이정도가 있음. 어차피 (e|q):suffix=nsfw 같은거 아니면 쓸사람만 쓰는 기능임
