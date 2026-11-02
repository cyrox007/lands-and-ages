/* Каталог профессий и действий. Анимация не управляет игровой экономикой. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyProfessionActions=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';

  const PACKS={
    porter:{
      name:'Носильщик',art:'villager-man-1',agent:true,
      actions:['idle','walk','pickup','carry','unload'],
      pending:[]
    },
    builder:{
      name:'Строитель',art:'builder',agent:true,
      actions:['idle','walk','lay_foundation','assemble_frame','finish_roof'],
      pending:['repair_building']
    },
    logger:{
      name:'Лесоруб',art:'logger',agent:true,
      actions:['idle','walk','fell_tree','carry_logs'],
      pending:['plant_tree']
    },
    quarry:{
      name:'Каменотёс',art:'quarry',agent:true,
      actions:['idle','walk','mine_stone','carry_stone'],
      pending:['sort_stone']
    },
    farmer:{
      name:'Земледелец',art:'farmer',agent:true,
      actions:['idle','walk','harvest_crop','carry_crop'],
      pending:['clear_field','sow_seed','tend_crop']
    },
    sawmill:{
      name:'Пильщик',art:'villager-man-2',agent:false,
      actions:['idle','saw_boards'],pending:['stack_boards']
    },
    mill:{
      name:'Мельник',art:'villager-man-2',agent:false,
      actions:['idle','grind_grain'],pending:['sift_flour']
    },
    bakery:{
      name:'Пекарь',art:'villager-woman-1',agent:false,
      actions:['idle','knead_dough'],pending:['bake_bread']
    },
    academy:{
      name:'Учёный',art:'villager-young-1',agent:false,
      actions:['idle','study_book'],pending:[]
    },
    theatre:{
      name:'Артист',art:'villager-woman-1',agent:false,
      actions:['idle','perform_scene'],pending:[]
    },
    market:{
      name:'Торговец',art:'villager-man-2',agent:false,
      actions:['idle','trade_goods'],pending:[]
    },
    embassy:{
      name:'Посол',art:'villager-man-1',agent:false,
      actions:['idle','write_letter'],pending:[]
    },
    barracks:{
      name:'Стражник',art:'villager-man-1',agent:false,
      actions:['idle','drill_guard'],pending:['patrol']
    }
  };
  const AT_WORK={
    sawmill:'saw_boards',mill:'grind_grain',bakery:'knead_dough',
    academy:'study_book',theatre:'perform_scene',market:'trade_goods',
    embassy:'write_letter',barracks:'drill_guard'
  };
  const result=(id,state)=>({id,state});
  function resolve(role,context={}){
    if(!PACKS[role])return result('idle','idle');
    const {phase,carrying,job,active,progress=0,cue,moving=false}=context;
    if(role==='porter'){
      if(cue==='pickup')return result('pickup','work');
      if(cue==='unload')return result('unload','work');
      if(carrying)return result('carry','carry');
      return job||moving?result('walk','walk'):result('idle','idle');
    }
    if(role==='builder'){
      if(phase==='work'){
        if(progress<.25)return result('lay_foundation','work');
        if(progress<.78)return result('assemble_frame','work');
        return result('finish_roof','work');
      }
      return phase==='travel'||moving?result('walk','walk'):result('idle','idle');
    }
    if(['logger','quarry','farmer'].includes(role)){
      if(phase==='work')
        return result({logger:'fell_tree',quarry:'mine_stone',farmer:'harvest_crop'}[role],'work');
      if(carrying)
        return result({logger:'carry_logs',quarry:'carry_stone',farmer:'carry_crop'}[role],'carry');
      if(['out','arrive','return'].includes(phase)||moving)return result('walk','walk');
      return result('idle','idle');
    }
    return active?result(AT_WORK[role]||'idle',AT_WORK[role]?'work':'idle'):
      result('idle','idle');
  }
  function artRole(role){return PACKS[role]?.art||role;}
  const actionsFor=role=>PACKS[role]?.actions.slice()||[];
  const pendingFor=role=>PACKS[role]?.pending.slice()||[];
  const roles=Object.keys(PACKS);
  return {PACKS,roles,actionsFor,pendingFor,artRole,resolve};
});
