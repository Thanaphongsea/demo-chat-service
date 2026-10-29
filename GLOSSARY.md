# ChatCall

An iOS messaging app where people chat one-to-one or in groups and start video calls from a conversation.

## Language

**Conversation**:
A one-to-one or group exchange of messages that a signed-in user can open from their list.
_Avoid_: Chat, thread, room (a Room is the backend's name for the same thing)

**Direct conversation**:
A Conversation between exactly two people, created implicitly by the first message.
_Avoid_: DM, 1:1 chat

**Group**:
A named Conversation with its own member list; it can have fewer than three members.
_Avoid_: Channel

**Roster**:
The complete current member list of a Group, read fresh before a call and never a truncated page.
_Avoid_: Member picker, participants (participants belong to a Call)

**Call**:
A live audio/video session started from a Conversation.
_Avoid_: Meeting, room

**Group call**:
A Call that invites every Roster member except the caller at once, up to 15 invitees (16 people in total), with no member selection.
_Avoid_: Conference, selective call

**Rejoin**:
Re-entering a Group call the user missed, declined or left while the Group call is still running.
_Avoid_: Redial, call back
