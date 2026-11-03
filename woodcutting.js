/* Видимый цикл рубки: подъем топора, удар, щепа и отклик дерева. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyWoodcutting=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';

  const FRAMES=8,FPS=7;
  // Координаты соответствуют художественному кадру рабочего 96×144.
  const POSES=[
    {hand:[55,76],head:[72,51],elbow:[68,65]},
    {hand:[56,62],head:[61,29],elbow:[71,53]},
    {hand:[56,51],head:[69,16],elbow:[70,43]},
    {hand:[66,57],head:[88,29],elbow:[77,45]},
    {hand:[76,73],head:[98,66],elbow:[79,60]},
    {hand:[72,78],head:[92,77],elbow:[74,65]},
    {hand:[61,77],head:[82,69],elbow:[71,70]},
    {hand:[56,74],head:[74,55],elbow:[68,66]}
  ];

  function frameAt(seconds){
    if(!Number.isFinite(seconds)||seconds<0)return 0;
    return Math.floor(seconds*FPS)%FRAMES;
  }
  function poseAt(frame){
    return POSES[((Math.floor(frame)%FRAMES)+FRAMES)%FRAMES];
  }
  function impact(frame){return [4,5].includes(((Math.floor(frame)%FRAMES)+FRAMES)%FRAMES);}
  function sway(seconds){
    const frame=frameAt(seconds);
    return frame===4?.048:frame===5?-.028:frame===6?.009:0;
  }

  function draw(ctx,x,footY,size,frame,direction='se'){
    if(!ctx||!Number.isFinite(size)||size<=0)return false;
    const p=poseAt(frame),hand=p.hand,head=p.head,elbow=p.elbow;
    const mirror=direction.endsWith('w'),scale=size/96;
    ctx.save();
    ctx.translate(x,footY-size*144/96);
    ctx.scale(scale,scale);
    ctx.translate(-48,0);
    if(mirror){ctx.translate(96,0);ctx.scale(-1,1);}

    // Рука — плечо, локоть и кисть; она двигается вместе с топором.
    ctx.lineCap='round';ctx.lineJoin='round';
    ctx.beginPath();ctx.moveTo(56,51);
    ctx.quadraticCurveTo(elbow[0],elbow[1],hand[0],hand[1]);
    ctx.strokeStyle='#493729';ctx.lineWidth=15;ctx.stroke();
    ctx.strokeStyle='#826345';ctx.lineWidth=10;ctx.stroke();
    ctx.beginPath();ctx.arc(hand[0],hand[1],4.7,0,Math.PI*2);
    ctx.fillStyle='#d3a67d';ctx.fill();
    ctx.lineWidth=1;ctx.strokeStyle='#785541';ctx.stroke();

    // Рукоять следует за кистью, положение лезвия отличается в каждом кадре.
    const dx=head[0]-hand[0],dy=head[1]-hand[1],length=Math.hypot(dx,dy);
    const startX=hand[0]-dx/length*11,startY=hand[1]-dy/length*11;
    ctx.beginPath();ctx.moveTo(startX,startY);ctx.lineTo(...head);
    ctx.lineWidth=6;ctx.strokeStyle='#493425';ctx.stroke();
    ctx.lineWidth=3.6;ctx.strokeStyle='#b48a5b';ctx.stroke();
    ctx.beginPath();ctx.moveTo(startX+1,startY);ctx.lineTo(head[0]+1,head[1]);
    ctx.lineWidth=1;ctx.strokeStyle='#e0b881';ctx.stroke();

    const angle=Math.atan2(dy,dx)+Math.PI/2;
    ctx.save();
    ctx.translate(...head);ctx.rotate(angle);
    ctx.beginPath();ctx.moveTo(-9,-5);ctx.lineTo(4,-7);
    ctx.lineTo(10,0);ctx.lineTo(4,11);ctx.lineTo(-9,8);ctx.closePath();
    ctx.fillStyle='#b9c6bd';ctx.fill();
    ctx.lineWidth=1.5;ctx.strokeStyle='#52635e';ctx.stroke();
    ctx.beginPath();ctx.moveTo(5,-6);ctx.lineTo(11,0);ctx.lineTo(5,10);
    ctx.lineWidth=2;ctx.strokeStyle='#eff3e2';ctx.stroke();
    ctx.restore();
    ctx.restore();
    return true;
  }

  function chips(ctx,x,y,size,seconds){
    const frame=frameAt(seconds);
    if(!impact(frame)||size<=0)return false;
    const strength=frame===4?1:.55;
    ctx.save();ctx.translate(x,y);
    ctx.lineCap='round';
    const offsets=[[-.14,-.13],[-.07,-.26],[.07,-.18],[.18,-.10],[.13,-.29]];
    for(let i=0;i<offsets.length;i++){
      const [ox,oy]=offsets[i],px=size*ox*strength,py=size*oy*strength;
      ctx.beginPath();
      ctx.moveTo(px,py);ctx.lineTo(px+size*.035,py-size*.065);
      ctx.lineWidth=Math.max(1,size*.022);
      ctx.strokeStyle=i%2?'#e8ba79':'#b77a46';
      ctx.stroke();
    }
    ctx.restore();
    return true;
  }
  return {FRAMES,FPS,frameAt,poseAt,impact,sway,draw,chips};
});