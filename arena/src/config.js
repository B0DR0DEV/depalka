export const SUPABASE_URL="https://igsgzujaduifeuqvjpmr.supabase.co";
export const SUPABASE_ANON_KEY="sb_publishable_yfZAX37cHmnx4TB73GDqlg_1M8R-Lyo";
export const GAME_SERVER_URL=location.hostname==="localhost"?"ws://localhost:2567":"wss://depost-arena-server.onrender.com";
export const SERVER_READY=false; // Set true after the Render service is deployed and /health responds.
export const getSession=()=>{try{return JSON.parse(localStorage.getItem("depost-auth2")||"null")}catch{return null}};
