import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import scoring from '../server-shared/fantasy_public_score.cjs';
import { createFantasyService } from '../fantasy.mjs';
import { createPageRenderer } from '../page-document.mjs';

function fixture() {
  const types = [1,2,2,2,3,3,3,3,4,4,4,1,2,3,4];
  return {
    bootstrap: { elements: types.map((type, index) => ({ id:index+1, web_name:`Player ${index+1}`, element_type:type, team:index+1 })), events: [{id:1, deadline_time:'2020-01-01',data_checked:false}], teams:[] },
    picks: { picks: types.map((_,index) => ({ element:index+1, position:index+1, multiplier:index===4?2:index<11?1:0, is_captain:index===4,is_vice_captain:index===5 })), entry_history:{event_transfers_cost:4}, automatic_subs:[] },
    live:{elements:types.map((_,index)=>({id:index+1,stats:{total_points:2,minutes:90}}))},
    fixtures:types.map((_,index)=>({id:index+1,event:1,team_h:index+1,team_a:99,started:true,finished:true})),
    event:{id:1,data_checked:false},
  };
}
test('public score applies captain and subtracts hits exactly once',()=>{const d=fixture();const score=scoring.scorePublicSquad(d);assert.equal(score.grossPoints,24);assert.equal(score.points,20);});
test('triple captain transfers full multiplier to playing vice captain',()=>{const d=fixture();d.picks.active_chip='3xc';d.live.elements[4].stats={minutes:0,total_points:0};const score=scoring.scorePublicSquad(d);assert.equal(score.players[5].multiplier,3);assert.equal(score.players[4].multiplier,0);assert.equal(score.grossPoints,26);});
test('double gameweek retains absent captain until remaining fixture ends',()=>{const d=fixture();d.live.elements[4].stats={minutes:0,total_points:0};d.fixtures.push({event:1,team_h:5,team_a:98,started:false,finished:false});const score=scoring.scorePublicSquad(d);assert.equal(score.substitutions.length,0);assert.equal(score.players[5].multiplier,1);});
test('substitutions preserve minimum formation and bench order',()=>{const d=fixture();d.live.elements[1].stats={minutes:0,total_points:0};d.live.elements[12].stats={minutes:0,total_points:0};const score=scoring.scorePublicSquad(d);assert.equal(score.substitutions.length,0);d.live.elements[12].stats={minutes:90,total_points:6};const replaced=scoring.scorePublicSquad(d);assert.deepEqual(replaced.substitutions,[{incoming:13,outgoing:2,confirmed:false}]);});
test('Bench Boost includes all fifteen players without substitutions',()=>{const d=fixture();d.picks.active_chip='bboost';const score=scoring.scorePublicSquad(d);assert.equal(score.grossPoints,32);assert.equal(score.substitutions.length,0);});
test('settled gameweeks trust official multipliers, including zero-point substitutions',()=>{const d=fixture();d.event.data_checked=true;d.picks.picks[1].multiplier=0;d.picks.picks[12].multiplier=1;d.picks.automatic_subs=[{element_in:13,element_out:2}];d.live.elements[12].stats={minutes:90,total_points:0};const score=scoring.scorePublicSquad(d);assert.equal(score.players[12].multiplier,1);assert.equal(score.substitutions[0].confirmed,true);assert.equal(score.grossPoints,22);});
test('blank-gameweek goalkeeper is replaced only by a goalkeeper',()=>{const d=fixture();d.live.elements[0].stats={minutes:0,total_points:0};d.fixtures=d.fixtures.filter(f=>f.team_h!==1);const score=scoring.scorePublicSquad(d);assert.equal(score.substitutions[0].incoming,12);});
test('negative player points remain negative and are multiplied',()=>{const d=fixture();d.live.elements[4].stats.total_points=-2;assert.equal(scoring.scorePublicSquad(d).points,12);});
test('standalone scoring bundle matches canonical API source',async()=>{assert.equal(await fs.readFile(new URL('../server-shared/fantasy_public_score.cjs',import.meta.url),'utf8'),await fs.readFile(new URL('../../api/fantasy_public_score.js',import.meta.url),'utf8'));});
test('service deduplicates shared requests and rejects partial snapshots',async()=>{
 const d=fixture();let calls=0;let fail=false;
 const service=createFantasyService(async url=>{calls++;if(url.includes('fixtures/')&&fail)throw new Error('offline');const body=url.includes('bootstrap-static')?d.bootstrap:url.includes('/picks/')?d.picks:url.includes('/live/')?d.live:url.includes('fixtures/')?d.fixtures:{id:1,name:'Example'};return new Response(JSON.stringify(body));});
 const results=await Promise.all([service.squad(1,1),service.squad(1,1)]);assert.equal(calls,5);assert.equal(results[0].points,20);
 const failing=createFantasyService(async url=>{if(url.includes('fixtures/'))throw new Error('offline');const body=url.includes('bootstrap-static')?d.bootstrap:url.includes('/picks/')?d.picks:url.includes('/live/')?d.live:{id:1};return new Response(JSON.stringify(body));});
 await assert.rejects(()=>failing.squad(1,1),/offline/);
 await assert.rejects(()=>service.squad(1,99),/not published/);
});
test('FPL direct route returns useful metadata without accessing a private API',async()=>{const template='<html><head><title>x</title></head><body><div id="root"></div></body></html>';const result=await createPageRenderer('https://invalid.example')(template,'/fpl?entry=1','https://scores.test');assert.equal(result.status,200);assert.match(result.html,/Fantasy Premier League/);assert.doesNotMatch(result.html,/Page not found/);});
test('SSR seeds the same explicit public squad without browser preferences',async()=>{
 const template='<html><head><title>x</title></head><body><div id="root"></div></body></html>';
 const example={profile:{id:42,name:'Example'},points:20};let received;
 const render=createPageRenderer('https://invalid.example',(_url,seed)=>{received=seed;return '<h1>Example</h1>';},v=>v,{squad:async(entry,event)=>{assert.equal(entry,42);assert.equal(event,3);return example;}});
 const result=await render(template,'/fpl?entry=42&event=3','https://scores.test');
 assert.equal(result.status,200);assert.deepEqual(received.fantasy,example);assert.equal(received.fantasyPath,'/api/fpl/entry/42?event=3');
});
test('a zero-minute booking counts as participation, matching the app',()=>{const d=fixture();d.live.elements[4].stats={minutes:0,total_points:-1,yellow_cards:1};const score=scoring.scorePublicSquad(d);assert.equal(score.players[4].multiplier,2);assert.equal(score.players[5].multiplier,1);assert.equal(score.substitutions.length,0);});
test('missing participation data never triggers a speculative substitution',()=>{const d=fixture();d.live.elements=d.live.elements.filter(p=>p.id!==5);assert.equal(scoring.scorePublicSquad(d).substitutions.length,0);});

test('squad exposes badges, league types and the next deadline',async()=>{
 const d=fixture();d.bootstrap.events.push({id:2,deadline_time:'2099-01-01T11:00:00Z'});
 const profile={id:1,name:'Example',club_badge_src:'https://example.test/badge.png',leagues:{classic:[{id:10,name:'Friends',league_type:'x'},{id:1,name:'Overall',league_type:'s'}]}};
 const service=createFantasyService(async url=>new Response(JSON.stringify(url.includes('bootstrap-static')?d.bootstrap:url.includes('/picks/')?d.picks:url.includes('/live/')?d.live:url.includes('fixtures/')?d.fixtures:profile)));
 const result=await service.squad(1,1);
 assert.equal(result.profile.club_badge_src,profile.club_badge_src);
 assert.equal(result.profile.leagues.classic[0].league_type,'x');
 assert.equal(result.nextDeadline,'2099-01-01T11:00:00Z');
});
