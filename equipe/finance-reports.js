const SUPABASE_URL='https://pmvvawbaqylspxfmxezw.supabase.co';
const SUPABASE_KEY='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';
const AUTH_KEY='barberium_staff_auth_v1';

const $=(s,r=document)=>r.querySelector(s);
const $$=(s,r=document)=>[...r.querySelectorAll(s)];
const esc=(v='')=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
const money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((Number(n)||0)/100);
const dateBR=v=>v?new Intl.DateTimeFormat('pt-BR',{day:'2-digit',month:'2-digit',year:'numeric'}).format(new Date(`${String(v).slice(0,10)}T12:00:00`)):'—';
const dateTimeBR=v=>v?new Intl.DateTimeFormat('pt-BR',{day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'}).format(new Date(v)):'—';

function getAuth(){try{return JSON.parse(localStorage.getItem(AUTH_KEY)||'null')}catch{return null}}
function saveAuth(v){localStorage.setItem(AUTH_KEY,JSON.stringify(v))}
async function authFetch(path,opts={}){
  const session=getAuth();
  const headers={apikey:SUPABASE_KEY,'Content-Type':'application/json',...(opts.headers||{})};
  if(session?.access_token)headers.Authorization=`Bearer ${session.access_token}`;
  let r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers});
  if(r.status===401&&session?.refresh_token){
    const rr=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{method:'POST',headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:session.refresh_token})});
    if(rr.ok){const refreshed=await rr.json();saveAuth(refreshed);headers.Authorization=`Bearer ${refreshed.access_token}`;r=await fetch(`${SUPABASE_URL}${path}`,{...opts,headers})}
  }
  const text=await r.text();let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
  if(!r.ok)throw new Error(data?.message||data?.msg||data?.error_description||data?.error||`Erro ${r.status}`);
  return data;
}
async function rpc(name,payload={}){return authFetch(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(payload)})}

function toast(msg){const e=$('#toast');if(!e)return; e.textContent=msg;e.classList.add('show');clearTimeout(toast.t);toast.t=setTimeout(()=>e.classList.remove('show'),2800)}
function openModal(eyebrow,title,html){const back=$('#modalBackdrop');if(!back)return;$('#modalEyebrow').textContent=eyebrow||'';$('#modalTitle').textContent=title||'';$('#modalBody').innerHTML=html;back.classList.remove('hidden');back.setAttribute('aria-hidden','false')}

function monthRange(month){
  const m=/^\d{4}-\d{2}$/.test(month||'')?month:new Date().toISOString().slice(0,7);
  const [y,mo]=m.split('-').map(Number);const end=new Date(y,mo,0).getDate();
  return [`${m}-01`,`${m}-${String(end).padStart(2,'0')}`];
}
function paymentMethodLabel(v){return({pix:'Pix',cash:'Dinheiro',debit:'Débito',credit:'Crédito'})[v]||v||'—'}
function statusLabel(v){return({paid:'Paga',predicted:'Prevista',open:'Em aberto',partial:'Parcial',settled:'Paga'})[v]||v||'—'}
function reportTypeLabel(v){return({complete:'Relatório financeiro completo',revenue:'Faturamento',payments:'Recebimentos, taxas e provedores',expenses:'Despesas',commissions:'Comissões',receivables:'Contas a receber',cash:'Caixa físico',dre:'DRE / Resultado'})[v]||v}
function safeName(v){return String(v||'relatorio').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'')}
function csvCell(v){const s=String(v??'');return `"${s.replaceAll('"','""')}"`}
function downloadBlob(content,type,name){const blob=content instanceof Blob?content:new Blob([content],{type});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;document.body.appendChild(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove()},700)}

function currentUnitOptions(){
  const src=$('#financeUnit');
  if(!src||!src.options.length)return '<option value="">Consolidado</option>';
  return [...src.options].map(o=>`<option value="${esc(o.value)}">${esc(o.textContent)}</option>`).join('');
}
function ensureButton(){
  if($('#financeReportButton'))return;
  const settings=$('#financeSettingsButton');
  if(!settings)return;
  const wrap=document.createElement('div');wrap.className='client-toolbar';wrap.style.marginTop='12px';
  const btn=document.createElement('button');btn.id='financeReportButton';btn.className='gold-btn';btn.type='button';btn.textContent='Gerar relatório';
  settings.parentNode.insertBefore(wrap,settings);wrap.appendChild(btn);wrap.appendChild(settings);
  settings.classList.remove('finance-wide');
}

function openFinanceReport(){
  const month=$('#financeMonth')?.value||new Date().toISOString().slice(0,7);const [start,end]=monthRange(month);
  const currentUnit=$('#financeUnit')?.value||'';const basis=$('#financeBasis')?.value||'cash';
  openModal('RELATÓRIO FINANCEIRO','Gerar relatório',`<form id="financeReportForm" class="form-grid">
    <div class="field"><label>Data inicial</label><input id="reportStart" type="date" value="${start}" required></div>
    <div class="field"><label>Data final</label><input id="reportEnd" type="date" value="${end}" required></div>
    <div class="field"><label>Unidade</label><select id="reportUnit">${currentUnitOptions()}</select></div>
    <div class="field"><label>Regime</label><select id="reportBasis"><option value="cash" ${basis==='cash'?'selected':''}>Caixa</option><option value="accrual" ${basis==='accrual'?'selected':''}>Competência</option></select></div>
    <div class="field"><label>Relatório</label><select id="reportType">
      <option value="complete">Financeiro completo</option>
      <option value="revenue">Faturamento</option>
      <option value="payments">Recebimentos, taxas e provedores</option>
      <option value="expenses">Despesas</option>
      <option value="commissions">Comissões</option>
      <option value="receivables">Contas a receber</option>
      <option value="cash">Caixa físico</option>
      <option value="dre">DRE / Resultado</option>
    </select></div>
    <div class="field"><label>Formato</label><select id="reportFormat"><option value="pdf">PDF</option><option value="csv">CSV</option></select></div>
    <p class="campaign-help">O relatório usa os lançamentos registrados no Barberium no período escolhido. “Consolidado” reúne todas as unidades.</p>
    <button id="generateFinanceReport" class="gold-btn" type="submit">Gerar relatório</button>
  </form>`);
  $('#reportUnit').value=currentUnit;
  $('#financeReportForm').onsubmit=generateFinanceReport;
}

async function generateFinanceReport(e){
  e.preventDefault();const btn=$('#generateFinanceReport');const start=$('#reportStart').value,end=$('#reportEnd').value,unit=$('#reportUnit').value||null,basis=$('#reportBasis').value,type=$('#reportType').value,format=$('#reportFormat').value;
  if(!start||!end||end<start){toast('Confira o período do relatório.');return}
  btn.disabled=true;btn.textContent='Gerando…';
  try{
    const data=await rpc('barberium_staff_finance_report',{p_start:start,p_end:end,p_unit_id:unit,p_basis:basis});
    if(format==='csv')exportCsv(data,type);else await exportPdf(data,type);
    toast('Relatório gerado.');
  }catch(err){toast(err?.message||'Não foi possível gerar o relatório.')}finally{btn.disabled=false;btn.textContent='Gerar relatório'}
}

function summaryRows(data){const o=data.overview||{};return [
  ['Receita bruta',money(o.gross_cents)],['Reembolsos',money(o.refunds_cents)],['Taxas',money(o.fees_cents)],['Receita líquida',money(o.net_received_cents)],['Comissões',money(o.commissions_cents)],['Despesas pagas',money(o.expenses_cents)],['Resultado operacional',money(o.operating_result_cents)],['Contas a receber',money(o.receivables_cents)]
]}
function revenueRows(data){
  if(data.meta?.basis==='accrual')return (data.accrual_revenue||[]).map(r=>[dateTimeBR(r.date),r.unit||'',r.customer||'',r.service||'',r.professional||'',money(r.amount_cents)]);
  return (data.payments||[]).map(r=>[dateTimeBR(r.date),r.unit||'',r.customer||'',r.service||'',r.professional||'',paymentMethodLabel(r.method),r.provider||'',money(r.amount_cents),money(r.fee_cents),money(r.net_cents)]);
}
function paymentRows(data){return (data.payments||[]).map(r=>[dateTimeBR(r.date),r.unit||'',r.customer||'',r.service||'',paymentMethodLabel(r.method),r.provider||'',r.installments||1,money(r.amount_cents),money(r.fee_cents),money(r.net_cents)])}
function refundRows(data){return (data.refunds||[]).map(r=>[dateTimeBR(r.date),r.unit||'',r.customer||'',r.description||'',paymentMethodLabel(r.method),money(r.amount_cents),r.reason||''])}
function expenseRows(data){return (data.expenses||[]).map(r=>[dateBR(r.due_date),r.unit||'',r.category||'Sem categoria',r.description||'',statusLabel(r.status),paymentMethodLabel(r.payment_method),r.paid_from_cash?'Sim':'Não',money(r.amount_cents),r.paid_at?dateTimeBR(r.paid_at):'',r.note||''])}
function commissionRows(data){return (data.commissions||[]).map(r=>[dateTimeBR(r.date),r.unit||'',r.professional||'',r.description||'',r.source_type||'',money(r.base_cents),r.rate_percent??'',money(r.amount_cents),statusLabel(r.status)])}
function receivableRows(data){return (data.receivables||[]).map(r=>[r.due_date?dateBR(r.due_date):'—',r.unit||'',r.customer||'',r.service||'',r.professional||'',money(r.original_due_cents),money(r.paid_cents),money(r.open_cents),statusLabel(r.status),r.note||''])}
function cashSessionRows(data){return (data.cash_sessions||[]).map(r=>[r.unit||'',dateTimeBR(r.opened_at),r.closed_at?dateTimeBR(r.closed_at):'Aberto',statusLabel(r.status),money(r.opening_balance_cents),money(r.expected_closing_cents),money(r.counted_closing_cents),money(r.difference_cents),r.closing_justification||''])}
function cashMovementRows(data){return (data.cash_movements||[]).map(r=>[dateTimeBR(r.date),r.unit||'',r.type||'',money(r.amount_cents),r.note||''])}
function providerRows(data){return (data.by_provider||[]).map(r=>[r.provider||'',paymentMethodLabel(r.method),r.installments||1,r.transactions||0,money(r.gross_cents),money(r.fees_cents),money(r.net_cents)])}
function unitRows(data){return (data.by_unit||[]).map(r=>[r.unit||'',money(r.gross_cents),money(r.fees_cents),money(r.net_cents)])}
function professionalRows(data){return (data.by_professional||[]).map(r=>[r.professional||'',r.completed_count||0,money(r.completed_cents),money(r.commission_cents)])}

function addCsvSection(lines,title,headers,rows){lines.push([title]);lines.push(headers);rows.forEach(r=>lines.push(r));lines.push([])}
function exportCsv(data,type){
  const lines=[];const meta=data.meta||{};addCsvSection(lines,'Barberium — Relatório financeiro',['Período','Unidade','Regime','Gerado em'],[[`${dateBR(meta.start)} a ${dateBR(meta.end)}`,meta.unit_name||'Consolidado',meta.basis==='cash'?'Caixa':'Competência',dateTimeBR(meta.generated_at)]]);
  if(type==='complete'||type==='dre')addCsvSection(lines,'Resumo / DRE',['Indicador','Valor'],summaryRows(data));
  if(type==='complete'||type==='revenue')addCsvSection(lines,'Faturamento',meta.basis==='accrual'?['Data','Unidade','Cliente','Serviço','Profissional','Valor']:['Data','Unidade','Cliente','Serviço','Profissional','Forma','Provedor','Bruto','Taxa','Líquido'],revenueRows(data));
  if(type==='complete'||type==='payments'){addCsvSection(lines,'Recebimentos',['Data','Unidade','Cliente','Serviço','Forma','Provedor','Parcelas','Bruto','Taxa','Líquido'],paymentRows(data));addCsvSection(lines,'Provedores e taxas',['Provedor','Forma','Parcelas','Transações','Bruto','Taxas','Líquido'],providerRows(data))}
  if(type==='complete'||type==='payments'||type==='revenue')addCsvSection(lines,'Reembolsos',['Data','Unidade','Cliente','Origem','Forma','Valor','Motivo'],refundRows(data));
  if(type==='complete'||type==='expenses')addCsvSection(lines,'Despesas',['Vencimento','Unidade','Categoria','Descrição','Situação','Forma','Saiu do caixa','Valor','Pago em','Observação'],expenseRows(data));
  if(type==='complete'||type==='commissions')addCsvSection(lines,'Comissões',['Data','Unidade','Profissional','Descrição','Origem','Base','Percentual','Comissão','Situação'],commissionRows(data));
  if(type==='complete'||type==='receivables')addCsvSection(lines,'Contas a receber',['Vencimento','Unidade','Cliente','Serviço','Profissional','Original','Pago','Em aberto','Situação','Observação'],receivableRows(data));
  if(type==='complete'||type==='cash'){addCsvSection(lines,'Sessões de caixa',['Unidade','Abertura','Fechamento','Situação','Fundo inicial','Esperado','Contado','Diferença','Justificativa'],cashSessionRows(data));addCsvSection(lines,'Movimentos de caixa',['Data','Unidade','Tipo','Valor','Observação'],cashMovementRows(data))}
  if(type==='complete'){addCsvSection(lines,'Consolidado por unidade',['Unidade','Bruto recebido','Taxas','Líquido'],unitRows(data));addCsvSection(lines,'Resumo por profissional',['Profissional','Atendimentos concluídos','Valor concluído','Comissões'],professionalRows(data))}
  const csv='\ufeff'+lines.map(r=>r.map(csvCell).join(';')).join('\n');const file=`barberium-${safeName(reportTypeLabel(type))}-${meta.start}-${meta.end}.csv`;downloadBlob(csv,'text/csv;charset=utf-8',file)
}

async function exportPdf(data,type){
  let jsPDF;try{({jsPDF}=await import('https://cdn.jsdelivr.net/npm/jspdf@2.5.2/+esm'))}catch{throw new Error('Não foi possível carregar o gerador de PDF. Verifique a internet.')}
  const doc=new jsPDF({unit:'mm',format:'a4'});let y=15;const left=14,maxWidth=182;
  const ensure=(need=8)=>{if(y+need>286){doc.addPage();y=15}};
  const line=(text,size=9,bold=false,indent=0)=>{doc.setFont('helvetica',bold?'bold':'normal');doc.setFontSize(size);const parts=doc.splitTextToSize(String(text??''),maxWidth-indent);for(const p of parts){ensure(5);doc.text(p,left+indent,y);y+=4.7}return parts.length};
  const title=t=>{ensure(12);y+=2;line(t,12,true);y+=1};
  const kv=(k,v)=>{ensure(6);doc.setFontSize(9);doc.setFont('helvetica','bold');doc.text(`${k}:`,left,y);doc.setFont('helvetica','normal');doc.text(String(v),left+42,y);y+=5};
  const meta=data.meta||{},o=data.overview||{};
  line('Scalabrini Barbieri — Barberium',16,true);line(reportTypeLabel(type),13,true);y+=2;kv('Período',`${dateBR(meta.start)} a ${dateBR(meta.end)}`);kv('Unidade',meta.unit_name||'Consolidado');kv('Regime',meta.basis==='cash'?'Caixa':'Competência');kv('Gerado em',dateTimeBR(meta.generated_at));
  if(type==='complete'||type==='dre'){
    title('Resumo / DRE');summaryRows(data).forEach(([k,v])=>kv(k,v));
  }
  const rowLines=(section,rows,formatter)=>{title(section);if(!rows.length){line('Nenhum registro no período.',9,false);return}rows.forEach((r,i)=>{ensure(10);line(formatter(r,i),8,false);y+=1})};
  if(type==='complete'||type==='revenue')rowLines('Faturamento',data.meta?.basis==='accrual'?(data.accrual_revenue||[]):(data.payments||[]),r=>data.meta?.basis==='accrual'?`${dateTimeBR(r.date)} • ${r.unit||''} • ${r.customer||'Cliente'} • ${r.service||''} • ${r.professional||''} • ${money(r.amount_cents)}`:`${dateTimeBR(r.date)} • ${r.unit||''} • ${r.customer||'Cliente'} • ${r.service||''} • ${paymentMethodLabel(r.method)}${r.provider?` / ${r.provider}`:''} • ${money(r.amount_cents)} • taxa ${money(r.fee_cents)} • líquido ${money(r.net_cents)}`);
  if(type==='complete'||type==='payments'){rowLines('Recebimentos e taxas',data.payments||[],r=>`${dateTimeBR(r.date)} • ${r.unit||''} • ${paymentMethodLabel(r.method)}${r.provider?` / ${r.provider}`:''}${r.method==='credit'?` ${r.installments||1}x`:''} • bruto ${money(r.amount_cents)} • taxa ${money(r.fee_cents)} • líquido ${money(r.net_cents)}`);rowLines('Resumo por provedor',data.by_provider||[],r=>`${r.provider||''} • ${paymentMethodLabel(r.method)}${r.method==='credit'?` ${r.installments||1}x`:''} • ${r.transactions||0} transações • bruto ${money(r.gross_cents)} • taxas ${money(r.fees_cents)} • líquido ${money(r.net_cents)}`)}
  if(type==='complete'||type==='payments'||type==='revenue')rowLines('Reembolsos',data.refunds||[],r=>`${dateTimeBR(r.date)} • ${r.unit||''} • ${r.customer||''} • ${r.description||''} • ${money(r.amount_cents)}${r.reason?` • ${r.reason}`:''}`);
  if(type==='complete'||type==='expenses')rowLines('Despesas',data.expenses||[],r=>`${dateBR(r.due_date)} • ${r.unit||''} • ${r.category||'Sem categoria'} • ${r.description||''} • ${statusLabel(r.status)} • ${money(r.amount_cents)}`);
  if(type==='complete'||type==='commissions')rowLines('Comissões',data.commissions||[],r=>`${dateTimeBR(r.date)} • ${r.unit||''} • ${r.professional||''} • ${r.description||''} • ${money(r.amount_cents)} • ${statusLabel(r.status)}`);
  if(type==='complete'||type==='receivables')rowLines('Contas a receber',data.receivables||[],r=>`${r.due_date?dateBR(r.due_date):'Sem vencimento'} • ${r.unit||''} • ${r.customer||''} • ${r.service||''} • em aberto ${money(r.open_cents)} • ${statusLabel(r.status)}`);
  if(type==='complete'||type==='cash'){rowLines('Sessões de caixa',data.cash_sessions||[],r=>`${r.unit||''} • abriu ${dateTimeBR(r.opened_at)} • ${r.closed_at?`fechou ${dateTimeBR(r.closed_at)}`:'aberto'} • fundo ${money(r.opening_balance_cents)} • diferença ${money(r.difference_cents)}`);rowLines('Movimentos de caixa',data.cash_movements||[],r=>`${dateTimeBR(r.date)} • ${r.unit||''} • ${r.type||''} • ${money(r.amount_cents)}${r.note?` • ${r.note}`:''}`)}
  if(type==='complete'){rowLines('Consolidado por unidade',data.by_unit||[],r=>`${r.unit||''} • bruto ${money(r.gross_cents)} • taxas ${money(r.fees_cents)} • líquido ${money(r.net_cents)}`);rowLines('Resumo por profissional',data.by_professional||[],r=>`${r.professional||''} • ${r.completed_count||0} atendimentos • ${money(r.completed_cents)} concluído • ${money(r.commission_cents)} em comissões`)}
  y+=4;line(`Resultado operacional do período: ${money(o.operating_result_cents)}`,10,true);
  doc.save(`barberium-${safeName(reportTypeLabel(type))}-${meta.start}-${meta.end}.pdf`)
}

function boot(){
  ensureButton();
  const btn=$('#financeReportButton');if(btn&&!btn.dataset.wired){btn.dataset.wired='1';btn.addEventListener('click',openFinanceReport)}
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
setTimeout(boot,500);
