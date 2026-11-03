/* Покадровые атласы рабочих: раздельные руки, ноги и инструменты. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyProfessionFrames=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const W=96,H=144,FRAMES=8,DIRECTIONS=['se','sw','ne','nw'];
  const ROLES={porter:0,builder:7,logger:8,quarry:9,farmer:10};
  const ACTIONS={
    porter:['walk','pickup','carry','unload'],
    builder:['walk','lay_foundation','assemble_frame','finish_roof'],
    logger:['walk','fell_tree','carry_logs'],
    quarry:['walk','mine_stone','carry_stone'],
    farmer:['walk','harvest_crop','carry_crop']
  };
  const CARRY=new Set(['carry','carry_logs','carry_stone','carry_crop']);
  const WORK=new Set(['pickup','unload','lay_foundation','assemble_frame',
    'finish_roof','fell_tree','mine_stone','harvest_crop']);
  const BEND={pickup:22,unload:20,lay_foundation:19,assemble_frame:7,
    finish_roof:-7,fell_tree:10,mine_stone:19,harvest_crop:26};
  const SWING=[-38,-59,-74,-21,54,33,4,-20];
  const STEP=[0,.7,1,.7,0,-.7,-1,-.7];
  const PALETTE={
    porter:{cloth:'#806344',light:'#b99c78',metal:'#c4b69b',hood:'#725139'},
    builder:{cloth:'#a98660',light:'#d5b58b',metal:'#cbd2cd',hood:'#68533d'},
    logger:{cloth:'#6c704a',light:'#aa9970',metal:'#d2d8d3',hood:'#5a4434'},
    quarry:{cloth:'#827d70',light:'#c3b59e',metal:'#d3d5ce',hood:'#777264'},
    farmer:{cloth:'#95836b',light:'#d2c4a1',metal:'#b6bda4',hood:'#937d62'}
  };
  const clamp=(n,a,b)=>Math.max(a,Math.min(b,n));
  const radians=degrees=>degrees*Math.PI/180;

  function pose(role,action,frame,direction='se'){
    if(!ACTIONS[role]?.includes(action)||!DIRECTIONS.includes(direction))
      throw new Error('Неизвестная профессия, действие или направление');
    const k=((Math.floor(frame)%FRAMES)+FRAMES)%FRAMES;
    const step=STEP[k],carry=CARRY.has(action),work=WORK.has(action);
    const swing=SWING[k]*(action==='harvest_crop'?.65:action==='mine_stone'?.92:1);
    const low=action==='harvest_crop'||action==='lay_foundation'||action==='pickup';
    const strong=action==='fell_tree'||action==='mine_stone'||action==='assemble_frame';
    const torso=work?(BEND[action]||0)+Math.sin(k*Math.PI/4)*(strong?8:4):step*1.1;
    const lift=work?(low?8:strong?-5:2):Math.abs(step)*1.8;
    const leftArm=work?clamp(-swing*.4,-34,39):step*(carry?10:24);
    const rightArm=work?clamp(swing*.7,-55,63):-step*(carry?7:24);
    return {role,action,frame:k,direction,back:direction[0]==='n',
      mirror:direction[1]==='w',torso:radians(torso*.32),bob:lift,
      leftArm:radians(leftArm),rightArm:radians(rightArm),
      leftLeg:radians(carry?step*13:work?step*2:step*23),
      rightLeg:radians(carry?-step*13:work?-step*2:-step*23),
      tool:radians(work?swing:0),crouch:Math.max(0,torso)*.19};
  }

  // Корпус из оригинальной художественной фигуры сохраняем целиком.
  // Прямоугольные маски по рукам обрезали плечи и вызывали «разобранных» юнитов.
  function fragment(g,img,index,rect,pivot,angle){
    g.save();
    g.translate(pivot[0],pivot[1]);
    g.rotate(angle);
    g.translate(-pivot[0],-pivot[1]);
    g.beginPath();
    g.rect(...rect);
    g.clip();
    g.drawImage(img,index*W,0,W,H,0,0,W,H);
    g.restore();
  }

  function drawFrame(g,img,role,action,frame,direction){
    if(!img?.naturalWidth)return false;
    const p=pose(role,action,frame,direction),index=ROLES[role];
    const working=WORK.has(action),carrying=CARRY.has(action);
    const stride=working?.24:carrying?.47:.43;
    const ankleLeft=p.leftLeg*stride,ankleRight=p.rightLeg*stride;

    g.save();
    if(p.mirror){g.translate(W,0);g.scale(-1,1);}

    // Цельный персонаж остаётся в каждом кадре, даже когда анимированные
    // части ноги перекрываются или смещаются. Груз рисуется отдельно в UI.
    g.drawImage(img,index*W,0,W,H,0,0,W,H);

    // Ноги берём из оригинального изображения, а не рисуем чужими линиями.
    // Поворот небольшой: суставы остаются под корпусом, ступни не исчезают.
    fragment(g,img,index,[0,89,49,55],[38,94],ankleLeft);
    fragment(g,img,index,[47,89,49,55],[59,94],ankleRight);

    // Полная ширина плеч, рук и головы. Никаких вырезанных «кусков» торса.
    g.save();
    g.translate(48,99);
    g.rotate(p.torso*(working?.72:.35));
    g.translate(-48,-99-p.bob*.12);
    g.drawImage(img,index*W,0,W,111,0,0,W,111);
    g.restore();

    // Пока нет рисованного северного ракурса, не подменяем лицо шаром:
    // сохраняем узнаваемый силуэт и лишь приглушаем освещение лица.
    if(p.back){
      g.save();
      g.globalCompositeOperation='source-atop';
      g.fillStyle='rgba(51,43,35,.19)';
      g.fillRect(24,8,52,35);
      g.restore();
    }
    g.restore();
    return true;
  }

  function create(img,role,action){
    if(!ACTIONS[role]?.includes(action)||!img?.naturalWidth)
      throw new Error('Нет графики или неверный анимационный пакет');
    if(typeof document==='undefined')throw new Error('Canvas недоступен');
    const canvas=document.createElement('canvas');
    canvas.width=W*FRAMES;canvas.height=H*DIRECTIONS.length;
    const g=canvas.getContext('2d');
    for(let row=0;row<DIRECTIONS.length;row++){
      for(let frame=0;frame<FRAMES;frame++){
        g.save();g.translate(frame*W,row*H);
        drawFrame(g,img,role,action,frame,DIRECTIONS[row]);
        g.restore();
      }
    }
    return canvas;
  }
  return {W,H,FRAMES,DIRECTIONS,ROLES,ACTIONS,pose,drawFrame,create};
});