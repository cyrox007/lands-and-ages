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

  function src(g,img,index){
    g.drawImage(img,index*W,0,W,H,0,0,W,H);
  }
  function fragment(g,img,index,rect,pivot,angle,shiftX=0,shiftY=0){
    g.save();
    g.translate(pivot[0]+shiftX,pivot[1]+shiftY);
    g.rotate(angle);
    g.translate(-pivot[0],-pivot[1]);
    g.beginPath();g.rect(...rect);g.clip();
    src(g,img,index);
    g.restore();
  }
  function stroke(g,points,width,color,light){
    g.lineCap='round';g.lineJoin='round';
    g.strokeStyle='#483727';g.lineWidth=width+2;
    g.beginPath();g.moveTo(...points[0]);
    for(const point of points.slice(1))g.lineTo(...point);
    g.stroke();
    g.strokeStyle=color;g.lineWidth=width-1;g.stroke();
    if(light){g.strokeStyle=light;g.lineWidth=Math.max(1,width*.22);g.stroke();}
  }
  function metal(g,points,fill){
    g.beginPath();g.moveTo(...points[0]);
    for(const p of points.slice(1))g.lineTo(...p);
    g.closePath();g.fillStyle=fill;g.fill();
    g.lineWidth=1.5;g.strokeStyle='#565750';g.stroke();
  }
  function arm(g,role,side,phase,working,carry){
    const p=PALETTE[role],right=side==='right';
    const shoulder=right?[64,49]:[32,49];
    const sign=right?1:-1;
    const activity=working?Math.sin(phase*Math.PI/4)*13:0;
    const walking=working?0:STEP[phase]*7;
    const elbow=[shoulder[0]+sign*(12+(right?activity*.23:-activity*.22)+walking*.65),
      69-(right?activity*.65:activity*.25)];
    const wrist=[elbow[0]-sign*(4+(working?activity*.29:walking*.5)),
      82-(right?activity*.9:activity*.5)-(carry?8:0)];
    // У руки собственное плечо, локоть и кисть, не один повёрнутый портрет.
    const gradient=g.createLinearGradient(shoulder[0],shoulder[1],wrist[0],wrist[1]);
    gradient.addColorStop(0,p.cloth);gradient.addColorStop(.55,p.light);
    gradient.addColorStop(1,p.cloth);
    g.lineJoin='round';g.lineCap='round';
    g.beginPath();g.moveTo(...shoulder);g.quadraticCurveTo(...elbow,...wrist);
    g.strokeStyle='#533f30';g.lineWidth=14;g.stroke();
    g.strokeStyle=gradient;g.lineWidth=10;g.stroke();
    g.beginPath();g.moveTo(elbow[0]-3,elbow[1]-3);g.lineTo(elbow[0]+3,elbow[1]+2);
    g.strokeStyle='#dfc4a1';g.lineWidth=1.1;g.stroke();
    g.fillStyle='#cd9f78';g.beginPath();
    g.ellipse(wrist[0],wrist[1],3.6,4.3,-.3,0,Math.PI*2);g.fill();
    g.strokeStyle='#956f53';g.lineWidth=.9;g.stroke();
    return wrist;
  }
  function tool(g,role,action,p,wrist){
    if(!WORK.has(action)||role==='porter')return;
    const metalColor=PALETTE[role].metal,angle=p.tool;
    const dx=Math.sin(angle),dy=-Math.cos(angle);
    const point=(offset,side=0)=>[wrist[0]+dx*offset+Math.cos(angle)*side,
      wrist[1]+dy*offset+Math.sin(angle)*side];
    const top=point(role==='builder'?26:32),bottom=point(-7);
    stroke(g,[bottom,top],role==='builder'?3.1:3.6,'#8d6040','#c9a073');
    if(role==='farmer'){
      g.beginPath();g.arc(top[0]+4,top[1],11,-Math.PI*.84,Math.PI*.18);
      g.strokeStyle='#5e6261';g.lineWidth=4.6;g.stroke();
      g.strokeStyle='#d1d8cd';g.lineWidth=2.6;g.stroke();
    }else if(role==='builder'){
      metal(g,[point(23,-7),point(29,-7),point(29,7),point(23,7)],metalColor);
    }else if(role==='quarry'){
      metal(g,[point(29,-11),point(33,-6),point(33,7),point(29,12)],metalColor);
    }else if(role==='logger'){
      metal(g,[point(28,-4),point(34,-7),point(37,6),point(30,10)],metalColor);
    }
  }
  function backOfHead(g,role){
    const p=PALETTE[role],gradient=g.createLinearGradient(32,9,69,41);
    gradient.addColorStop(0,p.hood);
    gradient.addColorStop(.55,p.cloth);
    gradient.addColorStop(1,'#493e32');
    g.fillStyle=gradient;g.beginPath();
    g.ellipse(49,29,19,17,-.08,0,Math.PI*2);g.fill();
    g.strokeStyle=p.light;g.lineWidth=2;
    g.beginPath();g.moveTo(33,36);g.quadraticCurveTo(49,42,65,34);g.stroke();
  }
  function drawFrame(g,img,role,action,frame,direction){
    if(!img?.naturalWidth)return false;
    const p=pose(role,action,frame,direction),index=ROLES[role];
    g.save();
    if(p.mirror){g.translate(W,0);g.scale(-1,1);}
    // Ноги и руки каждого кадра собраны раздельно; пятки остаются на поверхности.
    fragment(g,img,index,[9,84,45,60],[38,92],p.leftLeg,0,-p.crouch);
    fragment(g,img,index,[46,84,43,60],[61,92],p.rightLeg,0,-p.crouch);
    fragment(g,img,index,[30,36,36,71],[49,90],p.torso,0,-p.bob*.4);
    const active=WORK.has(action),carrying=CARRY.has(action);
    arm(g,role,'left',p.frame,active,carrying);
    const right=arm(g,role,'right',p.frame,active,carrying);
    if(p.back)backOfHead(g,role);
    else fragment(g,img,index,[23,3,52,43],[48,44],p.torso*.24,0,-p.bob*.35);
    tool(g,role,action,p,right);
    g.restore();return true;
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