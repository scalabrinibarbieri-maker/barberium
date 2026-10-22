import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { gradeExercise, correctAnswerLabel } from '../src/features/learning/engine.ts';
import { makeLetterTiles, composeLetterAnswer, canUseLetterBank } from '../src/features/learning/letterBank.ts';
import { parseCourseCatalog, parseCourseUnit, validLessonImageUrl } from '../src/features/courses/schema.ts';

const summary = {id:'it-a1-u02', language:'it',level:'A1',order:2,revision:1,title:'Explorando a Itália', subtitle:'Cultura',lessons:[{id:'it-a1-04', title:'Cultura e idioma',subtitle:'Uma lição',exerciseCount:2}]};
const intro = {type:'info',id:'q24',prompt:'O café italiano',instruction:'Cultura italiana', explanation:'Na Itália, o café acompanha diferentes momentos do dia.', category:'culture', image:{url:'https://images.example.org/cafe.jpg',alt:'Uma xícara de café', caption:'Um espresso tradicional'}};
const write = {type:'write',id:'q25',prompt:'Bom dia',instruction:'Escreva em italiano',explanation:'Bom dia em italiano',sampleAnswer:'Buongiorno',acceptedAnswers:['buongiorno']};

test('tela explicativa é aceita com imagem segura, mantendo outros tipos',()=>{
 const catalog = parseCourseCatalog({version:1, units:[summary]});
 const data = parseCourseUnit({version:1,unitId:summary.id,revision:1,lessons:[{...summary.lessons[0],unit:2,exercises:[intro,write]}]},catalog.units[0]);
 assert.equal(data.lessons[0].exercises[0].type,'info');
 assert.equal(data.lessons[0].exercises[1].type,'write');
 assert.equal(gradeExercise(intro,''),false);
 assert.equal(correctAnswerLabel(intro),'');
 assert.equal(gradeExercise(write,'BUONGIORNO'),true);
});

test('rejeita imagens maliciosas e documentos apenas explicativos',()=>{
 for (const url of ['http://site.com/a.png','file:///data/private','data:image/png;base64,a','https://localhost/img','https://127.0.0.1/a','https://name:pwd@example.com/x','https://foo.local/image','javascript:alert(1)']) assert.equal(validLessonImageUrl(url),false,url);
 assert.equal(validLessonImageUrl('https://images.example.org/cafe.jpg'),true);
 const catalog=parseCourseCatalog({version:1,units:[summary]});
 const doc = exercises => ({version:1,unitId:summary.id,revision:1,lessons:[{...summary.lessons[0],unit:2,exercises}]});
 assert.throws(()=>parseCourseUnit(doc([{...intro,image:{url:'https://localhost/a',alt:'oops'}},write]),catalog.units[0]));
 assert.throws(()=>parseCourseUnit(doc([intro,{...intro,id:'q26'}]),catalog.units[0]));
});

test('letras embaralhadas permitem repetir letras e voltar ao início',()=>{
 const tiles=makeLetterTiles('Buongiorno',9876);
 assert.equal(tiles.length,10);
 assert.equal(new Set(tiles.map(t=>t.id)).size,10);
 assert.notDeepEqual(tiles.map(x=>x.id),[0,1,2,3,4,5,6,7,8,9]);
 const seq=[...tiles].sort((a,b)=>a.id-b.id).map(t=>t.id);
 assert.equal(composeLetterAnswer('Buongiorno',tiles,seq),'Buongiorno');
 assert.equal(composeLetterAnswer('Buongiorno',tiles,seq.slice(0,-1)), 'Buongiorn');
 assert.equal(composeLetterAnswer('Buongiorno',tiles,[]),'');
 assert.equal(composeLetterAnswer('Buongiorno',tiles,[seq[0],seq[0],seq[1]]),'Bu');
 const phrase='mi chiamo Luca';
 const t=makeLetterTiles(phrase,42);
 assert.equal(composeLetterAnswer(phrase,t,t.slice().sort((a,b)=>a.id-b.id).map(x=>x.id)),phrase);
 assert.equal(canUseLetterBank('Ciao'),true);
 assert.equal(canUseLetterBank('x'.repeat(50)),false);
});

test('navegação não reinicia na aba selecionada e mantém telas protegidas',()=>{
 const home=readFileSync(new URL('../src/app/index.tsx',import.meta.url),'utf8');
 const layout=readFileSync(new URL('../src/app/_layout.tsx',import.meta.url),'utf8');
 const lesson=readFileSync(new URL('../src/app/lesson/[lessonId].tsx',import.meta.url),'utf8');
 const publisher=readFileSync(new URL('../backend/scripts/publish_course_packages.py',import.meta.url),'utf8');
 assert.match(home,/disabled=\{selected\} onPress=\{open\}/);
 assert.match(home,/if \(selected \|\| navigating\.current\) return/);
 assert.match(layout,/name="courses" options=\{\{ animation: 'fade'/);
 assert.match(layout,/name="lesson\/\[lessonId\]"/);
 assert.match(lesson,/infoCategory/);
 assert.match(lesson,/Entendi, continuar/);
 assert.match(lesson,/LetterBank/);
 assert.match(lesson,/completeLesson\(lesson\.id, count, lesson\.exercises\.length\)/);
 assert.match(publisher,/typ == 'info'/);
});
