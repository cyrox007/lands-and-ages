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
  function pose(state,frame,direction='se',seed=0){
    if(!STATES.includes(state)||!DIRECTIONS.includes(direction))
      throw new Error('Неизвестное состояние или направление персонажа');
    const f=((Math.floor(frame)%FRAMES)+FRAMES)%FRAMES;
    const wave=f*Math.PI/4;
    const step=Math.sin(wave),bounce=Math.abs(Math.sin(wave));
    const walking=state==='walk'||state==='carry';
    const working=state==='work';
    const weight=state==='carry'?.62:1;
    const lean=walking?step*1.7*weight:working?Math.sin(wave)*2.6:.35*Math.sin(wave+seed);
    const bob=walking?bounce*1.35:working?Math.abs(step)*.45:Math.sin(wave+seed)*.32;
    const swing=walking?step*3.4*weight:working?Math.sin(wave)*3.7:0;
    return {state,frame:f,direction,mirror:direction.endsWith('w'),
      bob:round(bob),lean:round(rad(lean)),left:round(step*swing*.08),
      right:round(-step*swing*.08),
      legA:round(rad(walking?step*5*weight:0)),
      legB:round(rad(walking?-step*5*weight:0)),
      upper:round(rad(working?Math.sin(wave)*5.5:walking?step*1.4:Math.sin(wave+seed)*.3))};
  }

  function draw(ctx,img,index,state,frame,direction,x,footY,size,seed=0){
    if(!img?.naturalWidth||index<0||size<=0)return false;
    const p=pose(state,frame,direction,seed),scale=size/WIDTH;
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
    ctx.restore();
    return true;
  }

  return {WIDTH,HEIGHT,FRAMES,DIRECTIONS,STATES,characterRole,pose,draw};
});
