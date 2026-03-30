import streamDeck, {
  action,
  KeyDownEvent,
  KeyUpEvent,
  SingletonAction,
} from "@elgato/streamdeck";

const HAMMERSPOON_URL = "http://127.0.0.1:27183";

async function sendCommand(command: string): Promise<void> {
  try {
    await fetch(`${HAMMERSPOON_URL}/${command}`);
  } catch {
    streamDeck.logger.error(`Failed to send command: ${command}`);
  }
}

@action({ UUID: "com.chuckconway.pedal-scroll.scroll-up" })
export class ScrollUpAction extends SingletonAction {
  override async onKeyDown(_ev: KeyDownEvent): Promise<void> {
    await sendCommand("scroll/up");
  }

  override async onKeyUp(_ev: KeyUpEvent): Promise<void> {
    await sendCommand("scroll/stop");
  }
}

@action({ UUID: "com.chuckconway.pedal-scroll.scroll-down" })
export class ScrollDownAction extends SingletonAction {
  override async onKeyDown(_ev: KeyDownEvent): Promise<void> {
    await sendCommand("scroll/down");
  }

  override async onKeyUp(_ev: KeyUpEvent): Promise<void> {
    await sendCommand("scroll/stop");
  }
}

@action({ UUID: "com.chuckconway.pedal-scroll.cycle-speed" })
export class CycleSpeedAction extends SingletonAction {
  override async onKeyDown(_ev: KeyDownEvent): Promise<void> {
    await sendCommand("scroll/speed");
  }
}
