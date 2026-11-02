/* Художественный пакет мельницы: реальные растровые спрайты из утверждённых листов. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyMillPack=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const path='assets/buildings/mill/';
  const cell=176;
  const atlases={
    start:'mill-states-start.webp',
    end:'mill-states-end.webp',
    parts:'mill-parts.webp'
  };
  const groups={
    start:['survey','frame','walls','almost','finished','idle','active','grain'],
    end:['flour','damaged','fresh_ruins','old_ruins','overgrown_ruins','restoring'],
    parts:['body_assembled','rotor','grain_sacks','flour_sacks',
      'millstone','miller','working_miller','crates']
  };
  const sprites={};
  for(const [atlas,keys] of Object.entries(groups))
    for(const [i,name] of keys.entries())
      sprites[name]={atlas,x:(i%4)*cell,y:Math.floor(i/4)*cell,w:cell,h:cell};
  const states={
    construction:['survey','frame','walls','roof'],
    production:['idle','working','damaged'],
    destruction:['fresh_ruins','old_ruins','overgrown_ruins'],
    restoration:['restoring','operational']
  };
  function constructionSprite(phase){
    return {survey:'survey',foundation:'survey',frame:'frame',
      walls:'walls',roof:'almost'}[phase]||'survey';
  }
  function stateSprite(phase){
    return {fresh_ruins:'fresh_ruins',old_ruins:'old_ruins',
      overgrown_ruins:'overgrown_ruins',restoring:'restoring',
      damaged:'damaged'}[phase]||'body_assembled';
  }
  // Нижняя видимая точка спрайта в его собственной ячейке 176×176.
  // Независимо от прозрачных полей все стадии стоят на одной земле.
  const spriteBottom={
    survey:135,frame:157,walls:156,almost:172,finished:172,
    idle:172,active:172,grain:172,flour:172,damaged:172,
    fresh_ruins:162,old_ruins:148,overgrown_ruins:151,restoring:142
  };
  function groundLevel(tileHeight){return tileHeight*.84;}
  function stageLayout(name,tileWidth,tileHeight){
    const size=tileWidth*1.94,bottom=spriteBottom[name]||172;
    return {size,left:-size/2,
      top:groundLevel(tileHeight)-size*bottom/cell,
      bottom:groundLevel(tileHeight)};
  }
  function layout(tileWidth,tileHeight){
    const width=tileWidth*2.18,height=width*316/360;
    const left=-width/2;
    const top=groundLevel(tileHeight)-height*284/316;
    const rotorWidth=width*186/360;
    return {
      width,height,left,top,
      hubX:left+width*135/360,
      hubY:top+height*148/316,
      rotorWidth,rotorHeight:rotorWidth*227/239
    };
  }
  return Object.freeze({
    id:'mill',version:4,path,cell,atlases,sprites,states,
    storage:{input:{grain:12},output:{flour:12}},
    recipe:{input:{grain:2},output:{flour:1},seconds:6,workers:1},
    // Координаты совпадают с пикселями исходного многослойного корпуса.
    detailed:{
      body:'mill-detailed-body.webp',rotor:'mill-detailed-rotor.webp',
      bodySize:{w:360,h:316},rotorSize:{w:239,h:227},
      hub:{x:135,y:148},rotorWidthInBody:186,
      renderWidthTiles:2.28,baseOffset:0.46
    },
    constructionSprite,stateSprite,layout,stageLayout,groundLevel
  });
});
