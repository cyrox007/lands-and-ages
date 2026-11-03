/* Единая точка опоры ступней и тени для жителей. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyUnitGround=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';

  // Исходная координата — нижняя видимая строка, а не край прозрачной ячейки.
  const RASTER={
    painted:{width:96,height:144,foot:140},
    logger:{width:96,height:144,foot:140},
    classic:{width:96,height:128,foot:125}
  };
  function spriteRect(x,y,width,kind='painted'){
    const frame=RASTER[kind];
    if(!frame||width<=0)throw new Error('Неверный формат кадра рабочего');
    const scale=width/frame.width;
    return {x:x-width/2,y:y-frame.foot*scale,
      width,height:frame.height*scale};
  }
  function footAt(rect,kind='painted'){
    const frame=RASTER[kind];
    return {x:rect.x+rect.width/2,y:rect.y+rect.width/frame.width*frame.foot};
  }
  function shadowRect(x,y,tileWidth,tileHeight,scale=.34){
    const width=tileWidth*1.1*scale,height=tileHeight*.57*scale;
    return {x:x-width/2,y:y-height/2,width,height};
  }
  return {RASTER,spriteRect,footAt,shadowRect};
});