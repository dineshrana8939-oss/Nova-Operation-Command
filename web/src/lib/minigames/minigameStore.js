import { writable } from 'svelte/store';
import { fetchNui } from '../api/nui.js';

export const minigameState = writable({
  active: false,
  game: 'lugnuts', // 'lugnuts' | 'skillcheck' | 'quicktime' | 'hotwire' | 'reaction'
  difficulty: 2,
  title: 'SKILL CHECK',
  duration: 15,
});

export function startMinigame(data) {
  minigameState.set({
    active: true,
    game: data.game || data.minigameType || 'lugnuts',
    difficulty: Number(data.difficulty) || 2,
    title: data.title || 'SKILL CHECK',
    duration: Number(data.duration) || 16,
  });
}

export function closeMinigame(success) {
  minigameState.update((s) => ({ ...s, active: false }));
  fetchNui('nova_convoytruck:minigame:finish', { success: !!success });
}
