import Foundation

/// Canonical presenter script for the narrow Order Rescue hero. Keeping these
/// transcripts in the shared core prevents the native replay, documentation,
/// and sidecar contract from drifting into different product stories.
public enum OrderRescueDemo {
    public static let initialRequest =
        "Take care of this delayed order. Check whether it has moved recently. "
        + "She looks like a valuable customer, so if it has been stuck for more "
        + "than three days, prepare an expedited replacement, apologize to her, "
        + "update the order, and remind me tomorrow to verify the new tracking."

    public static let correction =
        "Actually, don't create the replacement yet. Ask whether she would prefer "
        + "the replacement or a full refund. Give her a twenty-dollar store credit "
        + "either way, and tag Sarah in Slack because this is the third delayed "
        + "package from this carrier."
}
