export const SUPABASE_URL="https://igsgzujaduifeuqvjpmr.supabase.co";
export const SUPABASE_ANON_KEY="sb_publishable_yfZAX37cHmnx4TB73GDqlg_1M8R-Lyo";
export const GAME_SERVER_URL=location.hostname==="localhost"?"ws://localhost:2567":"wss://CHANGE-ME.example.com";
export const getSession=()=>{try{return JSON.parse(localStorage.getItem("depost-auth2")||"null")}catch{return null}};
