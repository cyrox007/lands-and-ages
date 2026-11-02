"""Подготовка прозрачных игровых спрайтов из утверждённого концепт-листа."""
from pathlib import Path
from PIL import Image, ImageFilter, ImageOps, ImageDraw
import numpy as np
import cv2
import json, shutil, zipfile

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'art/generated-drafts'
SRC_HQ=ROOT/'art/sources/headquarters-concept-original.png'
SRC_WORKERS=ROOT/'art/sources/workers-design-concept-original.png'
OUT.mkdir(exist_ok=True)

# Координаты фиксированы относительно исходных концепт-листов.
HQ_BOXES={
 'headquarters-level1':(16,78,384,409),
 'headquarters-foundation':(17,467,202,594),
 'headquarters-frame':(215,453,420,595),
 'headquarters-walls':(440,450,641,598),
 'headquarters-roof':(639,445,852,594),
 'headquarters-complete':(850,439,1054,597),
 'headquarters-light-damage':(18,860,188,994),
 'headquarters-heavy-damage':(189,857,359,994),
 'headquarters-fresh-ruins':(365,848,518,997),
 'headquarters-old-ruins':(532,848,686,998),
 'headquarters-module-core':(407,40,614,166),
 'headquarters-module-wing':(619,42,802,165),
 'headquarters-module-cupola':(788,28,947,173),
 'headquarters-module-roof':(953,43,1114,165),
 'headquarters-module-flag':(790,226,885,375),
 'headquarters-module-gate':(404,235,551,347),
 'headquarters-module-loading':(1159,210,1395,347),
}
WORKER_BOXES={
 'builder':(16,600,140,773),
 'porter':(135,599,262,775),
 'logger':(250,600,383,775),
 'quarry-worker':(380,600,511,775),
 'farmer':(500,600,653,775),
}
FRAME_X=[800,854,908,961,1013,1066,1119]
FRAME_Y={'walk':(612,684),'work':(681,746),'idle':(745,801),'carry':(796,846)}

def extract(source,rectangle,kind='light'):
    # Инициализация GrabCut фоном по краям и предметом внутри прямоугольника.
    img=np.asarray(source.crop(rectangle).convert('RGB'))
    h,w=img.shape[:2]
    bgr=cv2.cvtColor(img,cv2.COLOR_RGB2BGR)
    mask=np.full((h,w),cv2.GC_PR_BGD,np.uint8)
    margin=max(3,round(min(w,h)*.035))
    mask[:margin,:]=cv2.GC_BGD;mask[-margin:,:]=cv2.GC_BGD
    mask[:,:margin]=cv2.GC_BGD;mask[:,-margin:]=cv2.GC_BGD
    # Лёгкие бежевые/тёмные оттенки самого здания оставляем на усмотрение GrabCut.
    if kind=='light':
        hsv=cv2.cvtColor(img,cv2.COLOR_RGB2HSV)
        lab=cv2.cvtColor(img,cv2.COLOR_RGB2LAB).astype(np.float32)
        rim=np.concatenate([lab[:5,:,:].reshape(-1,3),lab[-5:,:,:].reshape(-1,3),lab[:, :5,:].reshape(-1,3),lab[:,-5:,:].reshape(-1,3)])
        bg=np.median(rim,axis=0)
        difference=np.linalg.norm(lab-bg,axis=2)
        mask[(difference>47)&(hsv[:,:,1]>45)]=cv2.GC_FGD
    else:
        # Цвет подложки плавный: оцениваем его вдоль каждой строки по боковым полям.
        # Так сохраняются тёмные сапоги и сумки, которые GrabCut мог бы удалить.
        left=np.median(img[:, :max(3,w//12), :],axis=1)
        right=np.median(img[:, -max(3,w//12):, :],axis=1)
        fraction=np.linspace(0,1,w)[None,:,None]
        backdrop=left[:,None,:]*(1-fraction)+right[:,None,:]*fraction
        difference=np.linalg.norm(img.astype(float)-backdrop,axis=2)
        mask[(difference>42)]=cv2.GC_FGD
        mask[(difference<13)]=cv2.GC_BGD
        mask[:4,:]=cv2.GC_BGD;mask[-4:,:]=cv2.GC_BGD
        mask[:,:4]=cv2.GC_BGD;mask[:,-4:]=cv2.GC_BGD
    if kind=='dark':
        silhouette=np.zeros((h,w),np.uint8)
        boundary=np.array([
            (.27,.01),(.74,.01),(.82,.18),(.95,.38),(.95,.70),
            (.86,.87),(.80,.99),(.20,.99),(.14,.87),(.05,.70),
            (.05,.38),(.18,.18)],np.float32)
        boundary[:,0]*=w;boundary[:,1]*=h
        cv2.fillPoly(silhouette,[boundary.astype(np.int32)],255)
        mask[silhouette==0]=cv2.GC_BGD
        mask[(difference>43)&(silhouette>0)]=cv2.GC_FGD
        mask[(difference>23)&(silhouette>0)&(mask!=cv2.GC_FGD)]=cv2.GC_PR_FGD
        mask[(difference<15)]=cv2.GC_BGD
    try:
        cv2.grabCut(bgr,mask,None,np.zeros((1,65),np.float64),np.zeros((1,65),np.float64),7,cv2.GC_INIT_WITH_MASK)
        alpha=np.where((mask==cv2.GC_FGD)|(mask==cv2.GC_PR_FGD),255,0).astype(np.uint8)
    except cv2.error:
        alpha=np.where(mask==cv2.GC_FGD,255,0).astype(np.uint8)
    # Удаляем изолированный шум и не затираем отдельные мелкие элементы вроде флага.
    num,components,stats,_=cv2.connectedComponentsWithStats(np.uint8(alpha>22))
    filtered=np.zeros_like(alpha)
    minimum=max(8,int(w*h*.00025))
    for index in range(1,num):
        if stats[index,cv2.CC_STAT_AREA]>=minimum:
            filtered[components==index]=255
    blur=cv2.GaussianBlur(filtered,(3,3),.65)
    rgba=np.dstack((img,blur))
    out=Image.fromarray(rgba,'RGBA')
    bbox=out.getbbox()
    return out.crop(bbox) if bbox else out

def pad_to_square(image,size=256):
    image=image.copy()
    image.thumbnail((size-14,size-14),Image.Resampling.LANCZOS)
    canvas=Image.new('RGBA',(size,size))
    canvas.alpha_composite(image,((size-image.width)//2,size-7-image.height))
    return canvas

hq=Image.open(SRC_HQ)
people=Image.open(SRC_WORKERS)
results={}
for name,rect in HQ_BOXES.items():
    picture=extract(hq,rect,'light')
    if name=='headquarters-level1': size=384
    elif name.startswith('headquarters-module'):size=192
    else:size=224
    picture=pad_to_square(picture,size)
    rel=f'headquarters/{name}.webp'
    (OUT/'headquarters').mkdir(exist_ok=True)
    picture.save(OUT/rel,'WEBP',lossless=False,quality=88,method=6)
    results[name]=rel
for name,rect in WORKER_BOXES.items():
    picture=pad_to_square(extract(people,rect,'dark'),224)
    rel=f'workers/{name}.webp'
    (OUT/'workers').mkdir(exist_ok=True)
    picture.save(OUT/rel,'WEBP',lossless=False,quality=85,method=6)
    results[name]=rel

# Существующий движок использует 8 кадров × 4 направления. Из концепта
# удалось независимо выделить только один профиль: остальные направления
# должны быть дорисованы, а не подделаны отражением передней стороны.
walk=[]
for x in FRAME_X:
    rect=(x-24,612,x+25,687)
    frame=pad_to_square(extract(people,rect,'dark'),96)
    walk.append(frame)
walk.append(walk[0].copy())
canvas=Image.new('RGBA',(96*8,128))
for i,frame in enumerate(walk):
    canvas.alpha_composite(frame,(i*96,32))
canvas.save(OUT/'workers/walk-reference-se.webp','WEBP',quality=90,method=6)

manifest={
 'version':1,
 'authoring':'Концепт-лист → ручная сетка вырезок → GrabCut → WebP',
 'origin':{'headquarters':SRC_HQ.name,'workers':SRC_WORKERS.name},
 'headquarters':{key:value for key,value in results.items() if key.startswith('headquarters-')},
 'roles':{key:value for key,value in results.items() if not key.startswith('headquarters-')},
 'walkReference':{'path':'workers/walk-reference-se.webp','frameWidth':96,'frameHeight':128,'frames':8,'directions':['se'],'status':'reference-only'},
 'notes':['В игре уже действует привязанная к расстоянию анимация носильщиков и строителей.','Оставшиеся три направления кадров надо отрисовать вручную в той же стилистике.','До завершения кадров старые анимации в игре следует оставить без изменений.']
}
(OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
(OUT/'README.md').write_text('''# Главное здание поселения и рабочие — первый художественный набор

Включены отдельные прозрачные WebP-заготовки: главное здание, пять стадий строительства, четыре состояния повреждения и старения, семь модульных деталей; персонажи пяти профессий; восьмикадровый референс ходьбы в одном направлении.

**Важно:** это нарезка из концепт-листов с автоматическим удалением фона. Требуется ручная коррекция краёв, регистрация опорных точек, согласование масштаба и дорисовка анимационных кадров по трём остальным ракурсам. Отдельные картинки **ещё не подключены к игровому Canvas**.

## Контракт анимации

- В игровом движке носильщики и строители уже движутся по маршрутам: координаты задаёт симуляция, а не анимация.
- Визуальная ходьба: 8 кадров на направление (`se`, `sw`, `ne`, `nw`), 4×8=32 кадра на профессию. Выбранный индекс кадра должен зависеть от расстояния, пройденного персонажем по карте.
- Опорная точка кадра — ступни. Сохранять один baseline и не перемещать всё изображение по вертикали искусственно.
- `idle`: отдельные 4 кадра; `work`: 8 кадров; `carry`: восемь кадров и груз отдельным слоем.
- При простое или остановке работ кадры и физические координаты должны оставаться согласованными с игровым состоянием.
- Для предотвращения спрайтового «плавания» нельзя использовать CSS-перемещение вместо физического маршрута.

## Исходники

Оригинальные художественные концепты вложены в `source/`. Скрипт `prepare_asset_pack.py` воспроизводит создание черновых спрайтов из них.
''',encoding='utf8')
(OUT/'source').mkdir(exist_ok=True)
shutil.copy2(Path(__file__),OUT/'source/prepare_asset_pack.py')

# Общий обзор: проверить читаемость силуэтов до внедрения в карту.
preview=Image.new('RGBA',(5*230,3*230),(38,43,37,255))
selection=['headquarters-level1','headquarters-foundation','headquarters-frame','headquarters-walls','headquarters-complete',*WORKER_BOXES.keys()]
for i,name in enumerate(selection):
    p=Image.open(OUT/results[name]).convert('RGBA')
    p.thumbnail((220,205),Image.Resampling.LANCZOS)
    px=(i%5)*230+(230-p.width)//2
    py=(i//5)*230+13
    preview.alpha_composite(p,(px,py))
preview.convert('RGB').save(ROOT/'headquarters-workers-preview.jpg',quality=91)
archive=ROOT/'lands-and-ages-hq-workers-pack.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=7) as z:
    for f in OUT.rglob('*'):
        if f.is_file():z.write(f,f.relative_to(OUT))
print('CREATED',archive,'size',archive.stat().st_size)
print('ASSETS',len(results)+1)