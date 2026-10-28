import './styles/theme.css';
import './lib/ui/picklist.js';   // one dark dropdown for every <select> (the browser's own popup is white and tiny in the game)
import App from './App.svelte';
import AuctionDui from './AuctionDui.svelte';

// The territory auction board is rendered by the game into a texture (a DUI) and hung over the projector: the same page,
// loaded with ?dui=auction, mounts only the board instead of the whole UI.
const asBoard = new URLSearchParams(window.location.search).get('dui') === 'auction';

const app = asBoard
  ? new AuctionDui({ target: document.getElementById('app') })
  : new App({ target: document.getElementById('app') });

export default app;
