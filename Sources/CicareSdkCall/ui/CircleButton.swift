import UIKit

public class CircleIconButton: UIView {
    public let button = UIButton(type: .custom)
    private let label = UILabel()
    private var action: (() -> Void)?
    private var normalBackgroundColor: UIColor
    private var iconColor: UIColor

    public init(icon: UIImage?,
                labelText: String,
                iconColor: UIColor = .white,
                backgroundColor: UIColor = .systemBlue,
                action: @escaping () -> Void) {
        self.normalBackgroundColor = backgroundColor
        self.iconColor = iconColor
        super.init(frame: .zero)
        self.action = action
        setupViews(icon: icon, text: labelText)
    }

    private func setupViews(icon: UIImage?, text: String) {
        button.setImage(icon?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = iconColor
        button.backgroundColor = normalBackgroundColor
        button.layer.cornerRadius = 32
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false

        button.adjustsImageWhenDisabled = false
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        label.text = text
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .black
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(button)
        addSubview(label)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 64),
            button.heightAnchor.constraint(equalToConstant: 64),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func handleTap() {
        guard button.isEnabled else { return }
        action?()
    }
    
    public var icon: UIImage? {
        get { button.currentImage }
        set {
            button.setImage(newValue?.withRenderingMode(.alwaysTemplate), for: .normal)
        }
    }

    public var isEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            if newValue {
                button.backgroundColor = normalBackgroundColor
                button.tintColor = iconColor
            } else {
                button.backgroundColor = normalBackgroundColor.withAlphaComponent(0.5)
                button.tintColor = iconColor.withAlphaComponent(0.5)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
