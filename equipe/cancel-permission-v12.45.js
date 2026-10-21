import { criarCliente } from '../shared/api.js?v=1';

/* Barberium v12.45 · cancelamento do barbeiro
   Corrige permissão viva + desvia o barbeiro do fluxo avançado v12.8.
*/
(() => {
  const $=(s,r=document)=>r.querySelector(s);
  const $$=(s,r=document)=>[...r.querySelectorAll(s)];
  let lastAppointmentId=null;
  let decorateToken=0;

  // Login e chamadas ao banco: shared/api.js (etapa 5).
  const api=criarCliente();
  function rpc(name,payload={}){return api.rpc(name,payload)}

  function toast(msg){
    const el=$('#toast');
    if(!el)return;
    el.textContent=msg;
    el.classList.add('show');
    clearTimeout(toast.t);
    toast.t=setTimeout(()=>el.classList.remove('show'),2800);
  }

  function closeModal(){
    const back=$('#modalBackdrop');
    if(!back)return;
    back.classList.add('hidden');
    back.setAttribute('aria-hidden','true');
    const body=$('#modalBody');
    if(body)body.innerHTML='';
  }

  function refreshAgenda(){
    const input=$('#dateInput');
    if(input?.value)input.dispatchEvent(new Event('change',{bubbles:true}));
  }

  async function currentContext(){
    const [me,catalog]=await Promise.all([
      rpc('barberium_staff_me'),
      rpc('barberium_staff_catalog')
    ]);
    return {
      role:me?.role||'barber',
      canCancel:['owner','admin'].includes(me?.role)||catalog?.permissions?.cancel_appointment===true
    };
  }

  function modalIsConfirmed(){
    return $$('#modalBody .detail-box strong')
      .some(x=>String(x.textContent||'').trim().toLowerCase()==='confirmado');
  }

  function removeExistingCancel(){
    $$('[data-new-status="cancelled"]').forEach(btn=>btn.remove());
    $$('[data-v1245-barber-cancel]').forEach(btn=>btn.remove());

    const ownRoot=$('#v1245StatusActions');
    if(ownRoot&&!ownRoot.children.length){
      const prev=ownRoot.previousElementSibling;
      if(prev?.matches?.('[data-v1245-title]'))prev.remove();
      ownRoot.remove();
    }
  }

  function ensureActionsRoot(){
    let root=$('#statusActions')||$('#v1245StatusActions');
    if(root)return root;

    const body=$('#modalBody');
    if(!body)return null;

    const title=document.createElement('h3');
    title.className='section-mini-title';
    title.dataset.v1245Title='1';
    title.textContent='Alterar status';

    root=document.createElement('div');
    root.className='action-row';
    root.id='v1245StatusActions';
    body.append(title,root);
    return root;
  }

  async function decorate(id){
    const token=++decorateToken;
    if(!id)return;

    try{
      const ctx=await currentContext();
      if(token!==decorateToken)return;

      // ADM continua exatamente no fluxo avançado já existente.
      if(['owner','admin'].includes(ctx.role))return;

      // Para barbeiro, removemos o botão que a v12.8 intercepta.
      removeExistingCancel();

      if(!ctx.canCancel||!modalIsConfirmed())return;

      const root=ensureActionsRoot();
      if(!root)return;

      const btn=document.createElement('button');
      btn.type='button';
      btn.className='danger-btn';
      btn.dataset.v1245BarberCancel=id;
      btn.textContent='Cancelado';
      root.appendChild(btn);
    }catch(err){
      console.error('Barberium v12.45:',err);
    }
  }

  async function cancelAsBarber(id,btn){
    if(!id||btn?.disabled)return;

    try{
      const ctx=await currentContext();

      if(['owner','admin'].includes(ctx.role)){
        toast('Use o cancelamento administrativo deste atendimento.');
        return;
      }

      if(!ctx.canCancel){
        btn?.remove();
        toast('Você não tem permissão para cancelar agendamentos.');
        return;
      }

      if(!confirm('Cancelar este agendamento?'))return;

      btn.disabled=true;
      btn.textContent='Cancelando…';

      await rpc('barberium_staff_set_appointment_status',{
        p_appointment_id:id,
        p_status:'cancelled'
      });

      toast('Agendamento cancelado.');
      closeModal();
      refreshAgenda();
    }catch(err){
      toast(err?.message||'Não foi possível cancelar o agendamento.');
      if(btn){
        btn.disabled=false;
        btn.textContent='Cancelado';
      }
    }
  }

  document.addEventListener('click',event=>{
    const appointment=event.target.closest?.('[data-appt-id]');
    if(appointment?.dataset?.apptId){
      lastAppointmentId=appointment.dataset.apptId;
      setTimeout(()=>decorate(lastAppointmentId),180);
      setTimeout(()=>decorate(lastAppointmentId),520);
      return;
    }

    const direct=event.target.closest?.('[data-v1245-barber-cancel]');
    if(direct){
      event.preventDefault();
      event.stopPropagation();
      cancelAsBarber(direct.dataset.v1245BarberCancel||lastAppointmentId,direct);
    }
  });

  const fromUrl=new URLSearchParams(location.search).get('appointment');
  if(/^[0-9a-f-]{36}$/i.test(fromUrl||'')){
    lastAppointmentId=fromUrl;
    setTimeout(()=>decorate(fromUrl),650);
    setTimeout(()=>decorate(fromUrl),1300);
  }

  document.addEventListener('visibilitychange',()=>{
    if(document.visibilityState==='visible'&&lastAppointmentId){
      setTimeout(()=>decorate(lastAppointmentId),180);
    }
  });
})();
