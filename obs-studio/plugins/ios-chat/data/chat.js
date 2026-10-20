/* iOS port: chat source page script.
 *
 * Runs in the app's own content world; scripts from page content are switched off (allowsContentJavaScript = NO)
 * and the page's Content-Security-Policy allows no scripts either. Message data comes from viewers: it is only
 * ever put into textContent, attribute values set through the DOM, and img.src for URLs the app has checked.
 * Nothing here parses HTML. */

'use strict';

const CHAT_SAFE_CLASS = /^[a-z0-9-]+$/;
const CHAT_SAFE_COLOR = /^#[0-9a-fA-F]{6}$/;
const CHAT_SAFE_SRC = /^(https:\/\/|data:image\/(png|gif|jpeg|webp);base64,)/;
const CHAT_UNSAFE = 'script, iframe, frame, object, embed, link, style, meta, base, form, svg, math, ' +
    '[onerror], [onload], [onclick], [onmouseover], [href], [srcdoc], [action]';

function chatSetStyle(css, width) {
    document.getElementById('chat-user').textContent = String(css);
    document.getElementById('chat-batch').style.width = Number(width) + 'px';
}

function chatImage(className, part, images) {
    const alt = typeof part.alt === 'string' ? part.alt : '';
    if (typeof part.src !== 'string' || !CHAT_SAFE_SRC.test(part.src)) {
        return document.createTextNode(alt);
    }
    const img = document.createElement('img');
    img.className = className;
    img.alt = alt;
    img.src = part.src;
    images.push(img);
    return img;
}

function chatMessage(message, images) {
    const root = document.createElement('div');
    root.className = 'chat-message';
    for (const name of Array.isArray(message.classes) ? message.classes : []) {
        if (typeof name === 'string' && CHAT_SAFE_CLASS.test(name)) {
            root.classList.add(name);
        }
    }
    if (typeof message.authorColor === 'string' && CHAT_SAFE_COLOR.test(message.authorColor)) {
        root.style.setProperty('--author-color', message.authorColor);
    }

    const badges = document.createElement('span');
    badges.className = 'badges';
    for (const badge of Array.isArray(message.badges) ? message.badges : []) {
        badges.appendChild(chatImage('badge', badge, images));
    }
    root.appendChild(badges);

    const author = document.createElement('span');
    author.className = 'author';
    author.textContent = typeof message.author === 'string' ? message.author : '';
    root.appendChild(author);

    if (typeof message.amount === 'string') {
        const amount = document.createElement('span');
        amount.className = 'amount';
        amount.textContent = message.amount;
        root.appendChild(amount);
    }

    const text = document.createElement('span');
    text.className = 'text';
    for (const part of Array.isArray(message.parts) ? message.parts : []) {
        if (typeof part.text === 'string') {
            text.appendChild(document.createTextNode(part.text));
        } else {
            text.appendChild(chatImage('emote', part, images));
        }
    }
    root.appendChild(text);
    return root;
}

function chatWait(promise, ms) {
    return Promise.race([promise, new Promise(resolve => setTimeout(resolve, ms))]);
}

/* Lays the messages out, waits for their images and fonts, and returns where each one is in CSS pixels.
 * Messages that would end below maxBottom are left for the next batch (the first one is always taken). */
async function chatRenderBatch(messages, maxHeight, maxBottom) {
    const batch = document.getElementById('chat-batch');
    batch.replaceChildren();
    const images = [];
    const counts = [];
    for (const message of messages) {
        const slot = document.createElement('div');
        slot.className = 'chat-slot';
        slot.style.maxHeight = Number(maxHeight) + 'px';
        const before = images.length;
        slot.appendChild(chatMessage(message, images));
        counts.push(images.length - before);
        batch.appendChild(slot);
    }

    await chatWait(Promise.all(images.map(img => img.decode().catch(() => {}))), 1500);
    await chatWait(document.fonts.ready, 1500);

    const rects = [];
    for (const slot of batch.children) {
        const rect = slot.getBoundingClientRect();
        if (rects.length > 0 && rect.bottom > maxBottom) {
            break;
        }
        rects.push([rect.top, rect.height]);
    }
    return {rects: rects, images: counts.slice(0, rects.length), unsafe: batch.querySelectorAll(CHAT_UNSAFE).length};
}

function chatBackground(color) {
    document.documentElement.style.background = color === 'black' || color === 'white' ? color : 'transparent';
}

/* Transparency check: left half transparent, right half opaque red */
function chatProbe(show) {
    let probe = document.getElementById('chat-probe');
    if (!probe) {
        probe = document.createElement('div');
        probe.id = 'chat-probe';
        probe.style.background = 'linear-gradient(to right, transparent 50%, #ff0000 50%)';
        document.body.appendChild(probe);
    }
    probe.style.display = show ? 'block' : 'none';
    document.getElementById('chat-batch').style.display = show ? 'none' : 'block';
}
