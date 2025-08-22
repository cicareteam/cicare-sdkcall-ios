import UIKit

class Alert: UIView {
    
    private var onDismiss: (() -> Void)?
    
    init(message: String, icon: UIImage?, onDismiss: (() -> Void)? = nil) {
        super.init(frame: UIScreen.main.bounds)
        self.onDismiss = onDismiss
        setupView(message: message, icon: icon)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView(message: String, icon: UIImage?) {
        self.backgroundColor = UIColor.black.withAlphaComponent(0.1) // background overlay
       
        // container toast
        let container = UIView()
        container.backgroundColor = UIColor.white
        container.layer.cornerRadius = 5
        container.layer.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        
        // icon
        let iconView = UIImageView(image: icon)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        
        // label
        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        
        var stack = UIStackView(arrangedSubviews: [iconView, label])
        if (icon == nil) {
            stack = UIStackView(arrangedSubviews: [label])
        }
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        container.addSubview(stack)
        self.addSubview(container)
        
        // Constraints
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            container.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9),
            
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
        ])
        
        // tap anywhere to dismiss
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        self.addGestureRecognizer(tapGesture)
    }
    
    @objc private func handleTap() {
        self.removeFromSuperview()
        onDismiss?() // trigger callback
    }
    
    func show(in parent: UIView) {
        parent.addSubview(self)
    }
}
