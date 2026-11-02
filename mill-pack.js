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
  return Object.freeze({
    id:'mill',version:2,path,cell,atlases,sprites,states,
    storage:{input:{grain:12},output:{flour:12}},
    recipe:{input:{grain:2},output:{flour:1},seconds:6,workers:1},
    rotorPivot:{x:-.104,y:.445,size:.536,hubOffsetY:.0625},
    constructionSprite,stateSprite
  });
});
