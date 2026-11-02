/* Анимация из утверждённых художественных персонажей, без изменения симуляции. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyPaintedMotion=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';

  const WIDTH=96,HEIGHT=144,FRAMES=8;
  const DIRECTIONS=['se','sw','ne','nw'];
  const STATES=['idle','walk','work','carry'];

  // У художественного носильщика на портрете уже нарисован мешок.
  // На карте берём свободную от груза одежду; настоящий груз рисуется движком.
  const porterBody='villager-man-1';
  const characterRole=role=>role==='porter'?porterBody:role;
  const rad=angle=>angle*Math.PI/180;
  const round=value=>Math.round(value*10000)/10000;
  const WORK_INTENSITY={
    fell_tree:2.1,mine_stone:1.65,harvest_crop:.78,
    lay_foundation:1.1,assemble_frame:1.35,finish_roof:1.05,
    saw_boards:1.4,grind_grain:.82,knead_dough:1.3,
    study_book:.55,perform_scene:1.7,trade_goods:.82,
    write_letter:.55,drill_guard:1.5,pickup:1,unload:1
  };
  const WORK_COLORS={
    fell_tree:'#d9a56a',mine_stone:'#cbd3c9',harvest_crop:'#ebd172',
    lay_foundation:'#baa383',assemble_frame:'#d9b079',
    finish_roof:'#edca84',saw_boards:'#ddbc8b',
    grind_grain:'#e3d6b7',knead_dough:'#e9d9ad',
    study_book:'#e7c893',perform_scene:'#dbb0d8',
    trade_goods:'#e5bf72',write_letter:'#ead5ac',
    drill_guard:'#c8d4ce',pickup:'#d4be98',unload:'#d4be98'
  };
  function pose(state,frame,direction='se',seed=0,action=''){
    if(!STATES.includes(state)||!DIRECTIONS.includes(direction))
      throw new Error('Неизвестное состояние или направление персонажа');
    const f=((Math.floor(frame)%FRAMES)+FRAMES)%FRAMES;
    const wave=f*Math.PI/4;
    const step=Math.sin(wave),bounce=Math.abs(Math.sin(wave));
    const intensity=WORK_INTENSITY[action]||1;
    const walking=state==='walk'||state==='carry';
    const working=state==='work';
    const weight=state==='carry'?.62:1;
    const lean=walking?step*1.7*weight:working?Math.sin(wave)*2.6*intensity:.35*Math.sin(wave+seed);
    const bob=walking?bounce*1.35:working?Math.abs(step)*.45:Math.sin(wave+seed)*.32;
    const swing=walking?step*3.4*weight:working?Math.sin(wave)*3.7:0;
    return {state,frame:f,direction,mirror:direction.endsWith('w'),
      bob:round(bob),lean:round(rad(lean)),left:round(step*swing*.08),
      right:round(-step*swing*.08),
      legA:round(rad(walking?step*5*weight:0)),
      legB:round(rad(walking?-step*5*weight:0)),
      upper:round(rad(working?Math.sin(wave)*5.5*intensity:walking?step*1.4:Math.sin(wave+seed)*.3))};
  }

  // Эффекты работы синхронизированы с ударом и не создают второго инструмента.
  function drawWorkEffect(ctx,action,frame){
    const color=WORK_COLORS[action];
    if(!color||typeof ctx.fillRect!=='function')return false;
    const wave=frame*Math.PI/4;
    const force=Math.max(0,Math.sin(wave));
    if(force<.18)return false;
    ctx.save();
    ctx.globalAlpha=force*.8;
    ctx.fillStyle=color;
    const count=action==='mine_stone'||action==='fell_tree'?5:3;
    for(let i=0;i<count;i++){
      const spread=(i-(count-1)/2)*5;
      const height=(1+i%3)*5*force;
      ctx.save();
      ctx.translate(75+spread,77-height);
      ctx.rotate((i-2)*.32);
      ctx.fillRect(-1.2,-1.2,2.4+(i%2),3.5+(i%3));
      ctx.restore();
    }
    ctx.restore();
    return true;
  }
  function draw(ctx,img,index,state,frame,direction,x,footY,size,seed=0,action=''){
    if(!img?.naturalWidth||index<0||size<=0)return false;
    const p=pose(state,frame,direction,seed,action),scale=size/WIDTH;
    ctx.save();
    ctx.translate(x,footY);
    ctx.scale(scale*(p.mirror?-1:1),scale);
    ctx.translate(-WIDTH/2,-HEIGHT);

    const image=()=>ctx.drawImage(img,index*WIDTH,0,WIDTH,HEIGHT,0,0,WIDTH,HEIGHT);
    // Покой и переноска с остановкой сохраняют исходный силуэт без разрывов.
    if(state==='idle'){
      ctx.translate(WIDTH/2,HEIGHT-3);
      ctx.rotate(p.lean);
      ctx.translate(-WIDTH/2,-HEIGHT+3-p.bob);
      image();
      ctx.restore();
      return true;
    }

    // Движение ног отделено от корпуса. Пятки остаются на координате симуляции.
    for(const [left,angle] of [[true,p.legA],[false,p.legB]]){
      ctx.save();
      ctx.beginPath();
      ctx.rect(left?-4:48,94,left?54:52,54);
      ctx.clip();
      ctx.translate(left?31:65,102);
      ctx.rotate(angle);
      ctx.translate(left?-31:-65,-102);
      image();
      ctx.restore();
    }

    // Корпус чуть наклоняется, ноги переступают; рисунок не едет по таймеру.
    ctx.save();
    ctx.beginPath();ctx.rect(-4,-4,104,104);ctx.clip();
    ctx.translate(48,95);
    ctx.rotate(p.upper+p.lean);
    ctx.translate(-48,-95-p.bob);
    image();
    ctx.restore();
    if(state==='work')drawWorkEffect(ctx,action,p.frame);
    ctx.restore();
    return true;
  }

  return {WIDTH,HEIGHT,FRAMES,DIRECTIONS,STATES,
    characterRole,pose,draw,drawWorkEffect};
});
