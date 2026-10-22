// v12.28/v12.47 (apresentação e manutenção) e v12.42 (salvar a aparência por XHR) saíram na
// etapa 7a: o cartão "Área do cliente" mora em equipe/area-do-cliente.js. Fica só a v12.29,
// que sai na etapa 7b (comissões do barbeiro).

/* Barberium v12.29 · correção cirúrgica de "Minhas comissões" para barbeiros.
   Bypassa a cadeia de interceptadores de fetch apenas nesta RPC.
   Nenhuma outra chamada da Área da Equipe é alterada. */
(() => {
  const previousFetch=window.fetch.bind(window);
  const TARGET=/\/rest\/v1\/rpc\/barberium_staff_my_commissions(?:\?|$)/;

  function headersObject(headers){
    if(!headers)return {};
    if(headers instanceof Headers)return Object.fromEntries(headers.entries());
    if(Array.isArray(headers))return Object.fromEntries(headers);
    return {...headers};
  }

  function xhrResponse(url,init={}){
    return new Promise((resolve,reject)=>{
      const xhr=new XMLHttpRequest();
      xhr.open(init.method||'GET',url,true);
      xhr.timeout=12000;

      for(const [key,value] of Object.entries(headersObject(init.headers))){
        if(value!=null)xhr.setRequestHeader(key,String(value));
      }

      if(init.signal){
        if(init.signal.aborted){xhr.abort();reject(new DOMException('Abortado','AbortError'));return}
        init.signal.addEventListener('abort',()=>xhr.abort(),{once:true});
      }

      xhr.onload=()=>{
        const responseHeaders=new Headers();
        const raw=xhr.getAllResponseHeaders().trim();
        if(raw){
          for(const line of raw.split(/[\r\n]+/)){
            const i=line.indexOf(':');
            if(i>0)responseHeaders.append(line.slice(0,i).trim(),line.slice(i+1).trim());
          }
        }
        resolve(new Response(xhr.responseText,{
          status:xhr.status,
          statusText:xhr.statusText,
          headers:responseHeaders
        }));
      };
      xhr.onerror=()=>reject(new TypeError('Falha de conexão ao carregar suas comissões.'));
      xhr.ontimeout=()=>reject(new Error('A conexão demorou mais que o esperado. Tente novamente.'));
      xhr.onabort=()=>reject(new DOMException('Abortado','AbortError'));

      xhr.send(init.body??null);
    });
  }

  window.fetch=function(input,init={}){
    const url=typeof input==='string'?input:input?.url;
    if(typeof url==='string'&&TARGET.test(url)){
      return xhrResponse(url,init);
    }
    return previousFetch(input,init);
  };
})();
