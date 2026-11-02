/* Мельница — первый самостоятельный пакет здания. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyMillPack=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const path='assets/buildings/mill/layers/';
  const layers={
    foundation:'foundation.svg',body:'body.svg',roof:'roof.svg',
    rotor:'rotor.svg',props:'props.svg',input:'input.svg',
    output:'output.svg',worker:'worker.svg',stone:'stone.svg',
    frame:'frame.svg',walls:'walls.svg',damage:'damage.svg',
    heavy:'heavy.svg',ruins:'ruins.svg',fresh:'fresh.svg',
    old:'old.svg',scaffold:'scaffold.svg'
  };
  const states={
    construction:['survey','foundation','frame','walls','roof'],
    production:['idle','working','damaged'],
    destruction:['fresh_ruins','old_ruins','overgrown_ruins'],
    restoration:['restoring','operational']
  };
  function constructionLayers(phase){
    const stages={
      survey:['foundation'],
      foundation:['foundation','scaffold'],
      frame:['foundation','frame','scaffold'],
      walls:['foundation','walls','scaffold'],
      roof:['foundation','body','roof','scaffold']
    };
    return stages[phase]||stages.survey;
  }
  function stateLayers(phase){
    if(phase==='fresh_ruins')return ['foundation','ruins','fresh'];
    if(phase==='old_ruins')return ['foundation','ruins','old'];
    if(phase==='overgrown_ruins')return ['foundation','ruins','old'];
    return ['foundation','body','roof','props'];
  }
  return Object.freeze({
    id:'mill',version:1,path,layers,states,
    storage:{input:{grain:12},output:{flour:12}},
    recipe:{input:{grain:2},output:{flour:1},seconds:6,workers:1},
    pivot:{x:128,y:106},anchor:{x:160,y:270},
    constructionLayers,stateLayers
  });
});
