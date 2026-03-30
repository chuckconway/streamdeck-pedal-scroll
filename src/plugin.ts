import streamDeck from "@elgato/streamdeck";
import { ScrollUpAction, ScrollDownAction, CycleSpeedAction } from "./actions/scroll";

streamDeck.actions.registerAction(new ScrollUpAction());
streamDeck.actions.registerAction(new ScrollDownAction());
streamDeck.actions.registerAction(new CycleSpeedAction());

streamDeck.connect();
