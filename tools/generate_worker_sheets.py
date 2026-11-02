from pathlib import Path
from io import BytesIO
from math import sin,cos,pi
from PIL import Image, ImageDraw
import cairosvg

ROOT=Path(__file__).resolve().parents[1]
ASSETS=ROOT/'assets'
ASSETS.mkdir(parents=True,exist_ok=True)
FW,FH=96,128
FRAMES=8
ROWS=4

def seg(x1,y1,x2,y2,stroke,w=8,edge='#493325'):
    return f'<path d="M {x1:.2f},{y1:.2f} L {x2:.2f},{y2:.2f}" fill="none" stroke="{edge}" stroke-width="{w+3}" stroke-linecap="round"/><path d="M {x1:.2f},{y1:.2f} L {x2:.2f},{y2:.2f}" fill="none" stroke="{stroke}" stroke-width="{w}" stroke-linecap="round"/>'

def cell(role,action,direction,frame):
    phase=2*pi*frame/FRAMES
    walking=action in ('walk','carry')
    hammer=action=='work'
    # Strongly distinct silhouettes, genuine leg stride and counter-swing.
    stride=sin(phase) if walking else 0
    lift=max(0,cos(phase)) if walking else 0
    bob=(2.8*abs(sin(phase))) if walking else (0.7*sin(phase) if hammer else 0)
    sway=1.9*sin(phase) if walking else 0
    near=direction in ('se','sw')
    mirror=direction in ('sw','nw')
    skin='#dbab78';boot='#422e24';pants='#424b3f' if role=='porter' else '#524330'
    coat='#735e43' if role=='porter' else '#b18b36'
    vest='#96774d' if role=='porter' else '#e2b64b'
    cap='#6a4b32' if role=='porter' else '#dda73a'
    arm='#a97c51' if role=='porter' else '#b88555'
    # feet anchored; no entire-image drifting; limbs articulate.
    leftHip=(42,79-bob);rightHip=(54,79-bob)
    lfoot=(37+stride*14,106-lift*7)
    rfoot=(60-stride*14,106-max(0,-cos(phase))*7)
    lknee=((leftHip[0]+lfoot[0])*.5+stride*5,91-lift*3)
    rknee=((rightHip[0]+rfoot[0])*.5-stride*5,91-max(0,-cos(phase))*3)
    layers=[]
    layers.append('<ellipse cx="48" cy="110" rx="22" ry="6" fill="#12231f" opacity=".24"/>')
    # far leg
    layers.extend([seg(*rightHip,*rknee,pants,8),seg(*rknee,*rfoot,pants,7),
        f'<ellipse cx="{rfoot[0]+3:.2f}" cy="{rfoot[1]+1:.2f}" rx="8" ry="4.2" fill="{boot}" stroke="#38261d" stroke-width="1.6"/>'])
    cy=-bob
    # far arm counter-swing
    f_sh=(56+sway*.3,59+cy);f_el=(62-stride*8,70+cy+abs(stride)*2);f_hand=(55-stride*9,79+cy)
    layers.extend([seg(*f_sh,*f_el,arm,7),seg(*f_el,*f_hand,skin,6)])
    # main body with shading panels / seam
    layers.append(f'<path d="M{36+sway:.2f},{54+cy:.2f} Q47,{50+cy:.2f} {60+sway:.2f},{54+cy:.2f} L64,{79+cy:.2f} Q48,{87+cy:.2f} 32,{79+cy:.2f}Z" fill="{coat}" stroke="#453b2d" stroke-width="2.2"/>')
    layers.append(f'<path d="M{39+sway:.2f},{55+cy:.2f} L{53+sway:.2f},{55+cy:.2f} L55,{81+cy:.2f} L38,{80+cy:.2f}Z" fill="{vest}" opacity=".9"/>')
    layers.append(f'<path d="M33,{79+cy:.2f} L63,{79+cy:.2f}" stroke="#4f3526" stroke-width="5"/>')
    layers.append(f'<circle cx="51" cy="{79+cy:.2f}" r="2.5" fill="#d9c188"/>')
    if role=='porter':
        layers.append(f'<path d="M37,{55+cy:.2f} L58,{78+cy:.2f}" stroke="#d2b27f" stroke-width="4.8" opacity=".95"/>')
    else:
        layers.append(f'<path d="M38,{58+cy:.2f} L55,{76+cy:.2f}" stroke="#e7d2a0" stroke-width="3.5" opacity=".8"/>')
    # visible forward leg: knee flex + planted boot
    layers.extend([seg(*leftHip,*lknee,pants,8),seg(*lknee,*lfoot,pants,7),
        f'<ellipse cx="{lfoot[0]+3:.2f}" cy="{lfoot[1]+1:.2f}" rx="8" ry="4.2" fill="{boot}" stroke="#39271e" stroke-width="1.5"/>'])
    # face and neck
    layers.append(f'<path d="M44,{49+cy:.2f} L51,{49+cy:.2f} L52,{59+cy:.2f} L43,{59+cy:.2f}Z" fill="{skin}"/>')
    layers.append(f'<ellipse cx="{49+sway*.2:.2f}" cy="{40+cy:.2f}" rx="12.2" ry="14.6" fill="{skin}" stroke="#724d35" stroke-width="2"/>')
    if near:
        layers.append(f'<ellipse cx="{53+sway*.2:.2f}" cy="{40+cy:.2f}" rx="1.4" ry="1.7" fill="#412a26"/>')
        layers.append(f'<path d="M51,{46+cy:.2f} l4,-1" stroke="#986645" stroke-width="1.6"/>')
    else:
        layers.append(f'<path d="M40,{43+cy:.2f} Q49,{46+cy:.2f} 58,{41+cy:.2f} L56,{33+cy:.2f} 42,{34+cy:.2f}Z" fill="#62442e"/>')
    if role=='builder':
        layers.append(f'<path d="M33,{32+cy:.2f} Q47,{16+cy:.2f} 64,{30+cy:.2f} L66,{35+cy:.2f} L31,{35+cy:.2f} Z" fill="{cap}" stroke="#926820" stroke-width="2.2"/>')
        layers.append(f'<path d="M31,{34+cy:.2f} L66,{34+cy:.2f}" stroke="#edc457" stroke-width="4.8" stroke-linecap="round"/>')
        layers.append(f'<path d="M47,{19+cy:.2f} L49,{30+cy:.2f}" stroke="#ffe0a1" stroke-width="2" opacity=".6"/>')
    else:
        layers.append(f'<path d="M34,{33+cy:.2f} Q36,{16+cy:.2f} 57,{22+cy:.2f} L64,{32+cy:.2f} L61,{37+cy:.2f} L33,{37+cy:.2f}Z" fill="{cap}" stroke="#493324" stroke-width="2"/>')
        layers.append(f'<path d="M34,{33+cy:.2f} L67,{32+cy:.2f}" stroke="#a37d53" stroke-width="3.8" stroke-linecap="round"/>')
    # articulated near arm; pick pose by action
    if hammer:
        # Hammer travels through raised, strike, recovery arcs. Note changing elbow and head, not a floating badge.
        a=-2.0+(1-cos(phase))*.72 #  -2 -> -0.56, clearly raised and lowered
        shoulder=(34,59+cy);elbow=(29+cos(a)*15,65+sin(a)*15+cy)
        hand=(elbow[0]+cos(a)*15,elbow[1]+sin(a)*15)
        layers.extend([seg(*shoulder,*elbow,arm,7),seg(*elbow,*hand,skin,6)])
        hx=hand[0]+cos(a)*17;hy=hand[1]+sin(a)*17
        layers.append(seg(hand[0],hand[1],hx,hy,'#705235',4))
        layers.append(f'<g transform="translate({hx:.2f},{hy:.2f}) rotate({(a+pi/2)*180/pi:.2f})"><rect x="-12" y="-5" width="24" height="10" rx="2" fill="#b6c0c2" stroke="#596971" stroke-width="2"/><path d="M-10,-3 H10" stroke="#e6e7dc" opacity=".8"/></g>')
    elif action=='carry':
        shoulder=(34,60+cy);elbow=(28,69+cy+stride*2);hand=(44,69+cy)
        layers.extend([seg(*shoulder,*elbow,arm,7),seg(*elbow,*hand,skin,6)])
        # Cargo is NOT painted into the body animation. The renderer selects
        # and positions one object using the carried resource from simulation.
        # A generic sack here duplicated bread with logs, stone, and grain.
    else:
        shoulder=(34,60+cy);elbow=(30+stride*8,72+cy);hand=(37+stride*12,84+cy)
        layers.extend([seg(*shoulder,*elbow,arm,7),seg(*elbow,*hand,skin,6)])
    # a few painterly texture scratches
    layers.append(f'<path d="M41,{61+cy:.2f} l1,11 M44,{62+cy:.2f} l1,11" stroke="#f4dfab" stroke-width=".8" opacity=".32"/>')
    body=''.join(layers)
    if mirror:body='<g transform="translate(96 0) scale(-1 1)">'+body+'</g>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 128" width="96" height="128">{body}</svg>'

def sheet(role,mode):
    atlas=Image.new('RGBA',(FW*FRAMES,FH*ROWS),(0,0,0,0))
    for row,direction in enumerate(['se','sw','ne','nw']):
        for f in range(FRAMES):
            svg=cell(role,mode,direction,f)
            png=cairosvg.svg2png(bytestring=svg.encode(),output_width=FW*2,output_height=FH*2)
            image=Image.open(BytesIO(png)).convert('RGBA').resize((FW,FH),Image.Resampling.LANCZOS)
            atlas.alpha_composite(image,(FW*f,FH*row))
    fn=f'worker-{role}-{mode}.webp';atlas.save(ASSETS/fn,format='WEBP',lossless=True,method=6)
    return fn,atlas

if __name__=='__main__':
    generated=[]
    for role,mode in [('porter','walk'),('porter','carry'),('builder','walk'),('builder','work')]:
        fn,atlas=sheet(role,mode)
        generated.append((fn,(ASSETS/fn).stat().st_size))
    print(generated)
    # Show user actual frames as GIF, not a mock static image.
    gif=[]
    for f in range(FRAMES):
        canvas=Image.new('RGBA',(96*2,128),(242,229,202,255))
        for i,(role,mode) in enumerate([('porter','walk'),('builder','work')]):
            atlas=Image.open(ASSETS/f'worker-{role}-{mode}.webp').convert('RGBA')
            canvas.alpha_composite(atlas.crop((f*FW,0,(f+1)*FW,FH)),(96*i,0))
        gif.append(canvas.convert('RGB'))
    gif[0].save(ROOT/'docs'/'workers-animation-preview.gif',save_all=True,append_images=gif[1:],duration=110,loop=0,optimize=True)
