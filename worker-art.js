/* Векторные покадровые атласы персонажей: 4 направления × 8 кадров. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyWorkerArt=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const WIDTH=96,HEIGHT=128,FRAMES=8;
  const DIRECTIONS=['se','sw','ne','nw'];
  const PALETTES={
    porter:{coat:'#956038',light:'#c4935a',shade:'#593821',trousers:'#65503a',hat:'#a86c3f',hair:'#694327'},
    builder:{coat:'#c39b59',light:'#e6bc75',shade:'#77512d',trousers:'#625143',hat:'#c79c4c',hair:'#654127'},
    logger:{coat:'#56754b',light:'#819c65',shade:'#354f36',trousers:'#6b513b',hat:'#73563b',hair:'#5c3525'},
    quarry:{coat:'#7e8380',light:'#b1afa0',shade:'#4b514e',trousers:'#555b5c',hat:'#8e8e79',hair:'#493b33'},
    farmer:{coat:'#8b7950',light:'#b9a372',shade:'#615332',trousers:'#68543a',hat:'#b59a5c',hair:'#674e34'},
    'villager-man-1':{coat:'#617c69',light:'#94a88b',shade:'#3a574b',trousers:'#5b5245',hat:'#806746',hair:'#594032'},
    'villager-man-2':{coat:'#906c53',light:'#b89573',shade:'#634a38',trousers:'#625644',hat:'#87634b',hair:'#624337'},
    'villager-woman-1':{coat:'#866c8d',light:'#bea0c2',shade:'#5e4a68',trousers:'#735e79',hat:'#a98ba7',hair:'#50352d'},
    'villager-young-1':{coat:'#648a93',light:'#a1c5c1',shade:'#405c68',trousers:'#5b5a52',hat:'#72979c',hair:'#47362c'}
  };
  const villagerRoles=['villager-man-1','villager-man-2','villager-woman-1','villager-young-1'];
  const ACTIONS=['idle','walk','work','carry'];
  const round=n=>Math.round(n*10)/10;
  const path=(d,fill,stroke='#473426',weight=2)=>'<path d="'+d+'" fill="'+fill+'" stroke="'+stroke+'" stroke-width="'+weight+'" stroke-linejoin="round" stroke-linecap="round"/>';
  const line=(d,color,weight)=>path(d,'none',color,weight);
  const ellipse=(cx,cy,rx,ry,fill)=>'<ellipse cx="'+cx+'" cy="'+cy+'" rx="'+rx+'" ry="'+ry+'" fill="'+fill+'"/>';
  const poly=(pts,fill,outline='#3d332b')=>'<polygon points="'+pts+'" fill="'+fill+'" stroke="'+outline+'" stroke-width="2" stroke-linejoin="round"/>';
  const tool=(role,angle)=>{
    if(role==='porter'||villagerRoles.includes(role))return '';
    const head=role==='logger'
      ?poly('60,41 75,38 75,49 64,52','#c5c6b8','#585e59')
      :role==='quarry'
        ?line('M55 43 Q70 34 82 43','#bdc4c1',8)
        :role==='farmer'
          ?line('M61 42 L76 42','#b1a580',7)
          :poly('59,38 74,38 75,47 60,47','#b8b9ad','#555d5a');
    return '<g transform="rotate('+round(angle)+' 57 72)">'+
      line('M55 77 L67 39','#74502c',5)+head+
      line('M55 76 L67 42','#c5a276',1.4)+'</g>';
  };
  function pose(role,action,direction,frame){
    const p=PALETTES[role];
    if(!p)return '';
    const back=direction[0]==='n',mirror=direction[1]==='w';
    const phase=frame*Math.PI/4,resting=action==='idle';
    const step=action==='work'||resting?0:Math.sin(phase);
    const bob=resting?Math.sin(phase)*.7:action==='work'?0:Math.abs(Math.sin(phase))*1.5;
    const arm=resting?Math.sin(phase)*2.8:action==='work'?Math.sin(phase)*9:step*(action==='carry'?4:10);
    const lift=action==='work'||resting?0:Math.max(0,step)*8;
    const liftOther=action==='work'||resting?0:Math.max(0,-step)*8;
    const leftFootX=round(37+step*10),rightFootX=round(55-step*10);
    const leftFootY=round(113-lift),rightFootY=round(113-liftOther);
    const leftKneeX=round(40+step*6),rightKneeX=round(54-step*6);
    const torsoY=round(-bob);
    const armLeft=round(-arm),armRight=round(arm);
    const toolAngle=action==='work'?Math.sin(phase)*34-13:0;
    const mirrorTransform=mirror?'translate(96 0) scale(-1 1)':'';
    const civilian=villagerRoles.includes(role),woman=role==='villager-woman-1',
      youth=role==='villager-young-1',elder=role==='villager-man-2';
    const rearLeg=path('M43 74 Q'+leftKneeX+' 91 '+leftFootX+' '+(leftFootY-6)+
      ' L'+(leftFootX-7)+' '+leftFootY+' Q'+(leftFootX-15)+' '+leftFootY+
      ' '+(leftFootX-10)+' '+(leftFootY-5)+' L34 77 Z',p.trousers);
    const nearLeg=path('M51 75 Q'+rightKneeX+' 94 '+rightFootX+' '+(rightFootY-7)+
      ' L'+(rightFootX+8)+' '+rightFootY+' Q'+(rightFootX+15)+' '+rightFootY+
      ' '+(rightFootX+8)+' '+(rightFootY-6)+' L56 78 Z',p.trousers);
    const leftBoot=path('M'+(leftFootX-8)+' '+(leftFootY-7)+' L'+(leftFootX+6)+' '+(leftFootY-7)+
      ' L'+(leftFootX+7)+' '+leftFootY+' L'+(leftFootX-12)+' '+leftFootY+' Z','#45352d');
    const rightBoot=path('M'+(rightFootX-7)+' '+(rightFootY-7)+' L'+(rightFootX+7)+' '+(rightFootY-7)+
      ' L'+(rightFootX+10)+' '+rightFootY+' L'+(rightFootX-12)+' '+rightFootY+' Z','#45352d');
    const leftArm=path('M36 47 Q'+round(31+armLeft*.45)+' 58 '+round(36+armLeft)+
      ' 75 L'+round(42+armLeft)+' 79 Q'+round(48+armLeft*.7)+' 58 45 51 Z',p.shade);
    const rightArm=path('M58 48 Q'+round(67+armRight*.5)+' 59 '+round(61+armRight)+
      ' 74 L'+round(54+armRight)+' 81 Q'+round(47+armRight*.5)+' 61 50 51 Z',p.light);
    const leftHand=ellipse(round(39+armLeft),77,5,5,'#c8966c');
    const rightHand=ellipse(round(58+armRight),78,5,5,'#d7a379');
    let costume=path('M39 44 Q48 41 58 46 L63 74 Q54 86 35 79 L33 58 Z','url(#coat)',p.shade,2.5)+
      line('M38 50 Q44 56 48 58','#e8c796',1.7)+
      path('M36 74 L62 73 L60 80 L36 81 Z','#6e4b2f',p.shade,1.5)+
      '<rect x="46" y="73" width="7" height="7" rx="1" fill="#c9ab72"/>';
    if(role==='builder')costume+=path('M43 58 L58 58 L56 86 L41 86 Z','#b28b50','#6c4b2c',1.5)+
      line('M46 61 L53 62','#eed29c',1.5);
    if(role==='farmer')costume+=line('M39 48 L49 76 L57 48','#d8c494',3);
    if(role==='logger')costume+=line('M35 64 L60 71','#a8bb80',3);
    if(role==='quarry')costume+=ellipse(48,67,3,3,'#d1bba2')+line('M38 49 L60 50','#ccd0c6',2);
    if(role==='porter')costume+=path('M39 51 Q46 59 52 74','none','#d5b18b',3);
    // Различимые мирные жители: сарафан, жилет, пояс, короткая куртка.
    if(woman)costume+=path('M36 65 Q47 61 60 66 L66 94 Q49 103 31 94 Z',
      '#987a9f','#54435c',2)+line('M39 67 L56 68','#ddc3a9',2);
    if(elder)costume+=path('M40 47 L57 48 L54 75 L44 76 Z',
      '#69533f','#433728',1.8)+line('M49 48 L48 72','#d1aa78',2);
    if(youth)costume+=path('M37 56 L60 56 L61 70 L35 70 Z',
      '#6897a0','#365b66',1.5)+line('M37 70 L61 70','#d1b57c',2);
    if(civilian&&!woman&&!elder&&!youth)costume+=
      line('M40 49 L52 76','#d7ba91',3);
    let face=back
      ?path('M38 19 Q48 12 58 23 L59 36 Q49 47 38 37 Z',p.hair,'#4d3226',2)
      :path('M39 23 Q48 14 58 24 L57 38 Q49 45 40 37 Z','#d1a077','#76533c',2);
    if(!back)face+=ellipse(53,30,1.7,2.1,'#503629')+
      line('M56 34 L59 35 L55 37','#9a6344',1.4)+
      (role==='porter'||role==='logger'||elder?
        path('M44 37 Q51 43 55 37','#70462f','#70462f',2):'');
    const hat=woman
      ?ellipse(48,21,20,4,'#c7acc3')+
        path('M35 21 Q37 12 49 12 Q60 13 62 22 L59 30 L37 28 Z',
          '#96749d','#654f70',2)
      :youth
        ?path('M35 24 Q37 14 48 13 Q59 13 61 23 Z','#668e9a','#435b64',2)+
          line('M44 24 L64 25','#b4cfca',2)
      :role==='farmer'
      ?ellipse(48,21,25,5,'#b99b5b')+path('M34 21 L36 11 Q48 5 60 12 L63 22 Z','#ad8b4f','#765c34')
      :role==='quarry'
        ?path('M33 25 Q34 10 48 9 Q63 10 64 25 Z','#a3a08b','#51483c')+ellipse(48,25,19,4,'#888876')
        :role==='builder'
          ?path('M34 24 Q34 11 48 10 Q63 10 65 24 Z','#c69c4b','#805b2c')+ellipse(51,24,19,3,'#d1a95b')
          :path('M36 23 Q36 13 47 12 Q60 13 61 22 L57 27 L36 26 Z',p.hat,'#624329')+
            line('M36 24 L63 25','#d4a06b',2.4);
    const gear=action==='work'?tool(role,toolAngle):'';
    const pack=back?path('M40 45 Q49 39 59 46 L64 69 Q50 81 37 70 Z',p.shade,p.hair,2):'';
    const idleGesture=resting&&civilian&&!back?
      line('M60 80 L'+round(64+Math.sin(phase)*3)+' '+round(74+Math.cos(phase)*2),
        '#d9b38d',2):'';
    const body='<g transform="translate(0 '+torsoY+')">'+
      leftArm+rearLeg+leftBoot+nearLeg+rightBoot+pack+costume+rightArm+
      leftHand+rightHand+idleGesture+ellipse(48,41,7,5,'#976440')+face+hat+gear+'</g>';
    return '<g transform="'+mirrorTransform+'">'+
      ellipse(48,115,22,5,'#17201d33')+body+'</g>';
  }
  function atlas(role,action){
    if(!PALETTES[role]||!ACTIONS.includes(action))throw new Error('Неизвестная профессия или действие');
    const p=PALETTES[role],cells=[];
    for(const direction of DIRECTIONS)
      for(let frame=0;frame<FRAMES;frame++){
        const row=DIRECTIONS.indexOf(direction);
        cells.push('<g data-direction="'+direction+'" data-frame="'+frame+
          '" transform="translate('+(frame*WIDTH)+' '+(row*HEIGHT)+')">'+
          pose(role,action,direction,frame)+'</g>');
      }
    return '<svg xmlns="http://www.w3.org/2000/svg" width="'+(WIDTH*FRAMES)+
      '" height="'+(HEIGHT*DIRECTIONS.length)+'" viewBox="0 0 '+(WIDTH*FRAMES)+
      ' '+(HEIGHT*DIRECTIONS.length)+'"><defs><linearGradient id="coat" x1="0" y1="0" x2="1" y2="0">'+
      '<stop offset="0" stop-color="'+p.shade+'"/><stop offset=".42" stop-color="'+p.coat+
      '"/><stop offset="1" stop-color="'+p.light+'"/></linearGradient></defs>'+
      cells.join('')+'</svg>';
  }
  return {WIDTH,HEIGHT,FRAMES,DIRECTIONS,ACTIONS,
    roles:Object.keys(PALETTES).filter(role=>!villagerRoles.includes(role)),
    villagerRoles,atlas};
});